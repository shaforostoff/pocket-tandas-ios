// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteAudioControl.swift
//  Pocket Tandas
//
//  Sender-side handle on the receiver's audio chain — EQ, master volume, and the
//  two disc restoration filters — used by the EQ and Volume buttons in Remote
//  Control mode. It mirrors what the receiver broadcasts and sends each edit as a
//  command; the receiver applies it to the same Equalizer / PlaybackEngine /
//  RestorationFilters its own UI drives and echoes the new state.
//
//  Unlike RemoteQueue (authoritative-read-only), edits here are applied
//  OPTIMISTICALLY: a slider must follow the finger, and a 40 ms round trip would
//  otherwise fight the drag. Echoes arriving within `quietWindow` of a local edit
//  are therefore held back — but kept, and applied once the drag settles, so the
//  receiver stays the final word (e.g. its own clamping, or a Reset's defaults).
//

import Foundation
import Observation

@Observable
final class RemoteAudioControl {
    private(set) var isEnabled = true
    private(set) var bands: [EQBand] = []
    private(set) var masterVolume: Float = 1.0

    private(set) var declickEnabled = false
    private(set) var dehumEnabled = false
    private(set) var declick = DeclickSettings()
    private(set) var dehum = DehumSettings()
    /// Read-only: what the receiver's detector holds, and how far its background
    /// analysis of the current track has got. Never edited here, so no optimistic
    /// path and no quiet window — they simply follow the broadcasts.
    private(set) var detectedLines: [DehumLine] = []
    private(set) var scoutPhase: RestorationScoutPhase = .idle
    private(set) var declickLatency: TimeInterval = 0

    /// False until the receiver has told us its settings — the panels stay disabled
    /// until then, so an edit can't be sent against values we invented.
    private(set) var hasSettings = false

    /// How long after a local edit inbound echoes are held back.
    @ObservationIgnored private static let quietWindow: TimeInterval = 0.6

    @ObservationIgnored private let link: PeerLink
    @ObservationIgnored private var lastSeq: UInt64 = 0
    @ObservationIgnored private var lastEditAt: Date?
    @ObservationIgnored private var pending: RemoteAudioSettings?
    @ObservationIgnored private var flushScheduled = false

    init(link: PeerLink) {
        self.link = link
    }

    // MARK: - Inbound state

    /// Apply a broadcast from the receiver (dropping stale/out-of-order ones).
    func apply(_ settings: RemoteAudioSettings) {
        guard settings.seq > lastSeq else { return }
        lastSeq = settings.seq
        hasSettings = true
        guard !isEditing else {
            pending = settings
            scheduleFlush()
            return
        }
        commit(settings)
    }

    /// A fresh receiver session restarts its seq counter — reset ours so its first
    /// broadcast isn't rejected as stale.
    func resetSeq() {
        lastSeq = 0
        pending = nil
    }

    /// Forget the receiver's settings when the link drops: the panels go back to
    /// "waiting", and the buttons stop badging a rig we can no longer reach.
    func clear() {
        resetSeq()
        hasSettings = false
        isEnabled = true
        bands = []
        masterVolume = 1
        declickEnabled = false
        dehumEnabled = false
        declick = DeclickSettings()
        dehum = DehumSettings()
        detectedLines = []
        scoutPhase = .idle
        declickLatency = 0
    }

    private func commit(_ settings: RemoteAudioSettings) {
        isEnabled = settings.eqEnabled
        bands = settings.bands
        masterVolume = settings.volume.clamped(to: 0...1)
        declickEnabled = settings.declickEnabled
        dehumEnabled = settings.dehumEnabled
        declick = settings.declick.sanitized()
        dehum = settings.dehum.sanitized()
        detectedLines = settings.dehumLines
        scoutPhase = settings.scoutPhase
        declickLatency = settings.declickLatency
    }

    private var isEditing: Bool {
        guard let lastEditAt else { return false }
        return Date().timeIntervalSince(lastEditAt) < Self.quietWindow
    }

    /// Apply the newest held-back broadcast once the drag has settled.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietWindow) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if self.isEditing {
                self.scheduleFlush()          // still dragging — check again later
            } else if let settings = self.pending {
                self.pending = nil
                self.commit(settings)
            }
        }
    }

    private func noteEdit() {
        lastEditAt = Date()
    }
}

// MARK: - EqualizerControlling (drives EQButton / EqualizerView in Remote Control mode)

extension RemoteAudioControl: EqualizerControlling {
    var isActive: Bool { isEnabled && bands.contains(where: \.isColouring) }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        noteEdit()
        link.send(.setEQEnabled(on))
    }

    func setGain(_ value: Float, bandID: Int) {
        mutate(bandID) { band in
            guard band.kind.hasGain else { return }
            band.gain = value.clamped(to: Equalizer.gainRange)
        }
    }

    func setFrequency(_ value: Float, bandID: Int) {
        mutate(bandID) { band in band.frequency = value.clamped(to: band.frequencyRange) }
    }

    func setBandwidth(_ value: Float, bandID: Int) {
        mutate(bandID) { band in
            guard band.kind.hasQ else { return }
            band.bandwidth = value.clamped(to: Equalizer.bandwidthRange)
        }
    }

    func setBandEnabled(_ on: Bool, bandID: Int) {
        guard let index = bands.firstIndex(where: { $0.id == bandID }),
              bands[index].kind.isCut else { return }
        bands[index].isEnabled = on
        noteEdit()
        link.send(.setEQBandEnabled(id: bandID, on: on))
    }

    /// Load a preset optimistically from the shared table; the receiver's own
    /// bands arrive in the echo and win if they ever differ.
    func apply(_ preset: EQPreset) {
        bands = Equalizer.bands(for: preset)
        noteEdit()
        // Flat has always been `.resetEQ`, and still is — a receiver on an older
        // build understands it, where it would drop `.setEQPreset` unread.
        link.send(preset == .flat ? .resetEQ : .setEQPreset(preset))
    }

    func reset() { apply(.flat) }

    private func mutate(_ bandID: Int, _ change: (inout EQBand) -> Void) {
        guard let index = bands.firstIndex(where: { $0.id == bandID }) else { return }
        change(&bands[index])
        noteEdit()
        let band = bands[index]
        link.send(.setEQBand(id: band.id, gain: band.gain,
                             frequency: band.frequency, bandwidth: band.bandwidth))
    }
}

// MARK: - VolumeControlling (drives VolumeButton / VolumeView in Remote Control mode)

extension RemoteAudioControl: VolumeControlling {
    func setMasterVolume(_ value: Float) {
        let level = value.clamped(to: 0...1)
        guard level != masterVolume else { return }
        masterVolume = level
        noteEdit()
        link.send(.setVolume(level))
    }
}

// MARK: - RestorationControlling (drives the Restoration rows in Remote Control mode)

extension RemoteAudioControl: RestorationControlling {
    var isRestorationActive: Bool { declickEnabled || dehumEnabled }

    func setDeclickEnabled(_ on: Bool) {
        declickEnabled = on
        noteEdit()
        link.send(.setDeclickEnabled(on))
    }

    func setDehumEnabled(_ on: Bool) {
        dehumEnabled = on
        noteEdit()
        link.send(.setDehumEnabled(on))
    }

    func updateDeclick(_ change: (inout DeclickSettings) -> Void) {
        change(&declick)
        declick = declick.sanitized()
        noteEdit()
        link.send(.setDeclick(declick))
    }

    func updateDehum(_ change: (inout DehumSettings) -> Void) {
        change(&dehum)
        dehum = dehum.sanitized()
        noteEdit()
        link.send(.setDehum(dehum))
    }

    /// Optimistically to the shared factory settings; the receiver's own defaults
    /// arrive in the echo and win if they ever differ — the same bargain reset()
    /// makes for the EQ.
    func resetDeclick() {
        declick = DeclickSettings()
        noteEdit()
        link.send(.resetDeclick)
    }

    func resetDehum() {
        dehum = DehumSettings()
        noteEdit()
        link.send(.resetDehum)
    }
}
