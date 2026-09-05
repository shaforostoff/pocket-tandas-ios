// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RestorationFilters.swift
//  Pocket Tandas
//
//  The two disc-restoration filters on the master bus — Declick and Dehum —
//  as one model object, the way `Equalizer` wraps the parametric EQ.
//
//  Tango is played off transfers of shellac and vinyl, and the two defects that
//  survive every transfer are impulsive (clicks and crackle) and narrowband
//  (mains hum, the off-frequency drones speed correction leaves behind, and the
//  rumble under them). One filter for each, both switched off by default so a
//  clean digital master is untouched until the DJ asks for something.
//
//  This class owns the settings, applies them to the audio unit, persists them,
//  and drives the per-track background analysis that lets Dehum start a record
//  with its lines already known — see DehumTrackScout.
//
//  Plain @Observable (not @MainActor) to match the app's other model objects —
//  see the observable-not-mainactor note. All access is from the main thread.
//

import Foundation
import AVFoundation
import Observation

@Observable
final class RestorationFilters {

    // MARK: - State

    /// Repair impulsive damage — clicks, ticks, the crackle of a worn groove.
    private(set) var declickEnabled = false
    /// Remove continuous narrowband tones, and optionally the rumble under them.
    private(set) var dehumEnabled = false

    private(set) var declick = DeclickSettings()
    private(set) var dehum = DehumSettings()

    /// Where the per-track analysis has got to, mirrored from the scout so the
    /// parameters overlay can show it.
    private(set) var scoutState: DehumTrackScout.State = .idle

    /// True when either filter is actually in circuit — badges the EQ button and
    /// the row in the EQ panel.
    var isActive: Bool { declickEnabled || dehumEnabled }

    /// The delay the declicker imposes, in seconds. It is the same whether the
    /// filter is engaged or not (the unit keeps the delay when bypassed, so
    /// switching it cannot move the audio), and it is worth showing because it
    /// is the one cost of having the node in the graph at all.
    var declickLatency: TimeInterval {
        guard let unit, unit.declick.latencyFrames > 0 else { return 0 }
        return Double(unit.declick.latencyFrames) / outputSampleRate
    }

    /// The node the PlaybackEngine inserts on the master bus, or nil if the
    /// in-process audio unit could not be instantiated — in which case the graph
    /// is wired up without it and the app plays on unrestored.
    @ObservationIgnored private(set) var node: AVAudioUnitEffect?
    @ObservationIgnored private var unit: RestorationAudioUnit?

    @ObservationIgnored private let scout = DehumTrackScout()
    @ObservationIgnored private let defaultsKey = "restoration.settings.v1"

    /// The track the current scan belongs to, so enabling Dehum part-way through
    /// a record can start one for the record that is actually playing.
    @ObservationIgnored private var currentTrack: URL?

    @ObservationIgnored private var outputSampleRate: Double = 44_100

    init() {
        loadPersisted()

        let node = RestorationAudioUnitFactory.makeNode()
        self.node = node
        self.unit = node?.auAudioUnit as? RestorationAudioUnit

        scout.onLines = { [weak self] lines in self?.adopt(lines) }
        scout.onStateChange = { [weak self] in
            guard let self else { return }
            scoutState = scout.state
        }

        applyAll()
    }

    // MARK: - Editing (from the UI)

    func setDeclickEnabled(_ on: Bool) {
        declickEnabled = on
        unit?.declick.bypassed = !on
        persist()
    }

    func setDehumEnabled(_ on: Bool) {
        dehumEnabled = on
        unit?.dehum.bypassed = !on
        persist()
        // Switched on part-way through a record: the live detector would need
        // the better part of a minute to find what the scan can hand over now.
        if on { startScoutIfWorthwhile() } else { scout.cancel() }
    }

    func updateDeclick(_ change: (inout DeclickSettings) -> Void) {
        change(&declick)
        unit?.declick.setParams(declick.coreParams)
        persist()
    }

    func updateDehum(_ change: (inout DehumSettings) -> Void) {
        let wasAutomatic = dehum.isAutomatic
        change(&dehum)
        unit?.dehum.setParams(dehum.coreParams)
        persist()
        // Pinning a frequency turns the search off, so a scan in flight has
        // nothing left to contribute; unpinning one puts it back in play.
        if dehum.isAutomatic != wasAutomatic {
            if dehum.isAutomatic { startScoutIfWorthwhile() } else { scout.cancel() }
        }
    }

    func resetDeclick() {
        declick = DeclickSettings()
        unit?.declick.setParams(declick.coreParams)
        persist()
    }

    func resetDehum() {
        dehum = DehumSettings()
        unit?.dehum.setParams(dehum.coreParams)
        persist()
        startScoutIfWorthwhile()
    }

    /// Lines the live detector currently holds, for the parameters overlay. Read
    /// from the audio unit each time it is asked for rather than published, so
    /// the overlay sees the tracker move.
    func liveLines() -> [DehumLine] {
        guard let unit else { return [] }
        var wire = [PTDehumLine](repeating: PTDehumLine(), count: Int(PTDehumMaxLines))
        let count = wire.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return unit.dehum.copyLines(base, max: buffer.count)
        }
        return (0..<count).map { DehumLine(id: $0, wire: wire[$0]) }
    }

    // MARK: - Track lifecycle (driven by the PlaybackEngine)

    /// A new record is on. Each one carries its own hum, so the lines from the
    /// last are dropped and the opening of this one is read in the background.
    ///
    /// Declick is deliberately NOT reset: it learns only the local noise floor,
    /// which converges in 30 ms, and the master bus runs on across a track change
    /// — throwing its window away would punch a hole in the audio for nothing.
    func trackChanged(to url: URL?) {
        currentTrack = url
        unit?.dehum.resetLines()
        startScoutIfWorthwhile()
    }

    /// Playback stopped: nothing to scout for.
    func playbackStopped() {
        currentTrack = nil
        scout.cancel()
    }

    /// Called by the engine once the graph is running, so `declickLatency` is
    /// quoted against the rate the unit actually renders at.
    func noteOutputSampleRate(_ rate: Double) {
        if rate > 0 { outputSampleRate = rate }
    }

    private func startScoutIfWorthwhile() {
        guard dehumEnabled, dehum.isAutomatic, let url = currentTrack else {
            scout.cancel()
            return
        }
        scout.scan(url: url, params: dehum.coreParams)
    }

    private func adopt(_ lines: [DehumLine]) {
        guard !lines.isEmpty, let unit else { return }
        let wire = lines.map(\.wire)
        wire.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            unit.dehum.adoptLines(base, count: buffer.count)
        }
        ptLog("dehum scouted \(lines.map { String(format: "%.2f Hz (%@)", $0.frequency, $0.routeLabel) }.joined(separator: ", "))")
    }

    // MARK: - Applying

    private func applyAll() {
        guard let unit else { return }
        unit.declick.bypassed = !declickEnabled
        unit.dehum.bypassed = !dehumEnabled
        unit.declick.setParams(declick.coreParams)
        unit.dehum.setParams(dehum.coreParams)
    }

    // MARK: - Persistence (one JSON blob in UserDefaults)

    private struct Snapshot: Codable {
        var declickEnabled: Bool
        var dehumEnabled: Bool
        var declick: DeclickSettings
        var dehum: DehumSettings
    }

    private func persist() {
        let snapshot = Snapshot(declickEnabled: declickEnabled, dehumEnabled: dehumEnabled,
                                declick: declick, dehum: dehum)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        declickEnabled = snapshot.declickEnabled
        dehumEnabled = snapshot.dehumEnabled
        declick = snapshot.declick
        dehum = snapshot.dehum
    }
}
