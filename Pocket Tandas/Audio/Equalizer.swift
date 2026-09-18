// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  Equalizer.swift
//  Pocket Tandas
//
//  The master-bus parametric EQ, built on AVAudioUnitEQ (part of AVFoundation —
//  no third-party dependency, nothing added to the binary). The PlaybackEngine
//  attaches `node` and wires it between the main mixer and the output; this class
//  owns the user-facing band parameters, applies them to the node, and persists
//  them across launches.
//
//  The six bands are El Espejero's "EQ 4 TJ" reading of a shellac transfer rather
//  than a generic low/mid/high: four working controls — BASS, REVERB, BRILLIANCE,
//  HISS — between two rails that are set once and forgotten, the ultra-low mud
//  below 30 Hz and the artifact region above 10 kHz. That is also, exactly, the
//  SSL-style channel strip the article recommends: a one-knob high pass, a
//  two-knob low shelf, two three-knob peaking bands, a two-knob high shelf.
//
//  A shelving or peaking band at 0 dB is mathematically transparent, so those four
//  are inaudible at rest. The two cut filters have no such position — they are
//  switched in and out instead, and `EQBand.isInCircuit` is what decides whether
//  the node runs a band at all. Bands that are doing nothing are bypassed, which
//  is the one place where the band count has any measurable CPU cost.
//
//  Plain @Observable (not @MainActor) to match the app's other model objects —
//  see the observable-not-mainactor note. All access is from the main thread.
//

import Foundation
import AVFoundation
import Observation

@Observable
final class Equalizer: EqualizerControlling {
    /// One adjustable band — see EQBand (shared with the EQ panel and the wire
    /// payload the remote receiver broadcasts).
    typealias Band = EQBand

    /// Slider ranges shared by every band.
    static let gainRange: ClosedRange<Float> = -12...12         // dB
    static let bandwidthRange: ClosedRange<Float> = 0.1...3.0   // octaves

    /// Whole-unit on/off. When off the node is bypassed (fully transparent).
    /// Settable only through `setEnabled` so the change reaches the node + disk.
    private(set) var isEnabled: Bool = true

    /// The six bands, low → high. Edited through the `set*` methods so each
    /// change is mirrored to the audio node and persisted.
    private(set) var bands: [Band]

    /// True when the EQ would actually colour the sound — used to badge the EQ
    /// button so the DJ can see at a glance that EQ is in effect. The two rails
    /// at their default corners deliberately don't count; see EQBand.isColouring.
    var isActive: Bool {
        isEnabled && bands.contains(where: \.isColouring)
    }

    /// What the chain is actually rendering at, for the response curve.
    ///
    /// A bus format is only meaningful — and only safe to ask an AVAudioUnit for —
    /// once the engine has the node; on a detached one AVFoundation can raise,
    /// which in an app is an abort. Before then, and if the engine has no rate yet,
    /// assume the commonest one: the curve is a picture, and the difference between
    /// 44.1 and 48 kHz is a hair at the very top of it.
    var sampleRate: Double {
        guard node.engine != nil else { return 44100 }
        let rate = node.outputFormat(forBus: 0).sampleRate
        return rate > 0 ? rate : 44100
    }

    /// The audio node the PlaybackEngine inserts on the master bus.
    @ObservationIgnored let node = AVAudioUnitEQ(numberOfBands: 6)
    /// v2: the band table changed shape entirely at the "EQ 4 TJ" rework, so a v1
    /// blob is not migrated — there is no honest mapping from a peaking "Low" at
    /// 120 Hz onto a low shelf plus a high pass. v1 is left on disk untouched so a
    /// downgrade still finds its settings; an upgrade opens on the Flat preset.
    @ObservationIgnored private let defaultsKey = "equalizer.settings.v2"

    init() {
        bands = Self.defaultBands()
        loadPersisted()
        configureNode()
    }

    // MARK: - The band table

    static func defaultBands() -> [Band] {
        [
            Band(id: 0, name: "Low Cut", kind: .highPass,
                 caption: "Ultra-low mud. Set once: it keeps the rumble off the speakers and lets the bass below be generous.",
                 frequency: 30, isEnabled: true, frequencyRange: 20...120),
            Band(id: 1, name: "Bass", kind: .lowShelf,
                 caption: "The foundation the recording amplifier took out. Boost freely, but keep the corner below 150 Hz or the sound muddies.",
                 frequency: 100, frequencyRange: 40...300),
            Band(id: 2, name: "Reverb Cut", kind: .peak,
                 caption: "Echo added by a careless transfer. A few dB down at 1 kHz is plenty — deeper cuts get creepy.",
                 frequency: 1000, bandwidth: EQBandwidth.octaves(forQ: 1.0),
                 frequencyRange: 300...3000),
            Band(id: 3, name: "Brilliance", kind: .peak,
                 caption: "The sparkle, right where the shellac still has signal. Raise it liberally; Hiss Cut cleans up after it.",
                 frequency: 6000, bandwidth: EQBandwidth.octaves(forQ: 1.2),
                 frequencyRange: 2000...12000),
            Band(id: 4, name: "Hiss Cut", kind: .highShelf,
                 caption: "Groove noise. Pull it down as far as the record needs — Brilliance keeps the music.",
                 frequency: 7500, frequencyRange: 4000...12000),
            Band(id: 5, name: "High Cut", kind: .lowPass,
                 caption: "No music up here, only mp3 and transfer artifacts. Switch it in on the noisiest transfers.",
                 frequency: 10000, isEnabled: false, frequencyRange: 5000...20000),
        ]
    }

    /// The article's three starting points. Each returns a whole band table rather
    /// than a diff, so applying one can never leave a stale value behind.
    static func bands(for preset: EQPreset) -> [Band] {
        var table = defaultBands()
        switch preset {
        case .flat:
            break
        case .goldenAge:
            // The worked example: bass up, brilliance up, hiss down, both rails in.
            // Reverb stays at zero — the article is emphatic that it is only for
            // records that actually have objectionable reverb.
            table[1].gain = 6
            table[3].gain = 6
            table[4].gain = -6
            table[5].isEnabled = true
        case .post1950:
            // Tape masters and RIAA vinyl reach 20 Hz–20 kHz on their own, so the
            // only thing worth keeping is the ultra-low rail. Brilliance moves up
            // to where it lives on these records, ready but at zero.
            table[3].frequency = 11000
        }
        return table
    }

    // MARK: - Editing (from the UI)

    func setEnabled(_ on: Bool) {
        isEnabled = on
        node.bypass = !on
        persist()
    }

    func setGain(_ value: Float, bandID: Int) {
        mutate(bandID) { band in
            guard band.kind.hasGain else { return }
            band.gain = value.clamped(to: Self.gainRange)
        }
    }

    func setFrequency(_ value: Float, bandID: Int) {
        mutate(bandID) { band in band.frequency = value.clamped(to: band.frequencyRange) }
    }

    func setBandwidth(_ value: Float, bandID: Int) {
        mutate(bandID) { band in
            guard band.kind.hasQ else { return }
            band.bandwidth = value.clamped(to: Self.bandwidthRange)
        }
    }

    func setBandEnabled(_ on: Bool, bandID: Int) {
        mutate(bandID) { band in
            guard band.kind.isCut else { return }
            band.isEnabled = on
        }
    }

    func apply(_ preset: EQPreset) {
        bands = Self.bands(for: preset)
        applyAll()
        persist()
    }

    /// Restore every band to its factory frequency / bandwidth / gain (flat).
    func reset() { apply(.flat) }

    private func mutate(_ bandID: Int, _ change: (inout Band) -> Void) {
        guard let idx = bands.firstIndex(where: { $0.id == bandID }) else { return }
        change(&bands[idx])
        apply(bands[idx])
        persist()
    }

    // MARK: - Node application

    private func configureNode() {
        node.bypass = !isEnabled
        node.globalGain = 0
        applyAll()
    }

    private func applyAll() { bands.forEach(apply) }

    private func apply(_ band: Band) {
        guard band.id < node.bands.count else { return }
        let params = node.bands[band.id]
        params.filterType = band.kind.filterType
        // Written straight through, without consulting the node's rate: the unit
        // clamps its own parameters, and asking a not-yet-attached AVAudioUnit for
        // a bus format to pre-clamp against is both unnecessary and unsafe.
        params.frequency = band.frequency
        if band.kind.hasQ { params.bandwidth = band.bandwidth }
        if band.kind.hasGain { params.gain = band.gain }
        // A band that isn't doing anything doesn't need to be computed. The switch
        // is silent: a gain band only falls out of circuit within 0.05 dB of flat,
        // where its output already equals its input.
        params.bypass = !band.isInCircuit
    }

    // MARK: - Persistence (one JSON blob in UserDefaults)

    private struct Snapshot: Codable {
        struct BandState: Codable {
            var frequency: Float
            var bandwidth: Float
            var gain: Float
            var isEnabled: Bool = true

            init(frequency: Float, bandwidth: Float, gain: Float, isEnabled: Bool) {
                self.frequency = frequency
                self.bandwidth = bandwidth
                self.gain = gain
                self.isEnabled = isEnabled
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                frequency = try c.decode(Float.self, forKey: .frequency)
                bandwidth = try c.decode(Float.self, forKey: .bandwidth)
                gain = try c.decode(Float.self, forKey: .gain)
                isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            }
        }
        var isEnabled: Bool
        var bands: [BandState]
    }

    private func persist() {
        let snapshot = Snapshot(
            isEnabled: isEnabled,
            bands: bands.map { .init(frequency: $0.frequency, bandwidth: $0.bandwidth,
                                     gain: $0.gain, isEnabled: $0.isEnabled) })
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.bands.count == bands.count else { return }
        isEnabled = snapshot.isEnabled
        for i in bands.indices {
            bands[i].frequency = snapshot.bands[i].frequency.clamped(to: bands[i].frequencyRange)
            bands[i].bandwidth = snapshot.bands[i].bandwidth.clamped(to: Self.bandwidthRange)
            bands[i].gain = bands[i].kind.hasGain
                ? snapshot.bands[i].gain.clamped(to: Self.gainRange) : 0
            bands[i].isEnabled = bands[i].kind.isCut ? snapshot.bands[i].isEnabled : true
        }
    }
}

// MARK: - Kind → AVAudioUnitEQ

private extension EQBandKind {
    /// The AVAudioUnitEQ filter behind each band. The two passes are the SDK's
    /// "simple Butterworth 2nd order" pair (12 dB/octave, −3 dB at the corner);
    /// the shelves are the non-resonant ones, so their slope is fixed and no
    /// bandwidth is written for them.
    var filterType: AVAudioUnitEQFilterType {
        switch self {
        case .highPass:  return .highPass
        case .lowShelf:  return .lowShelf
        case .peak:      return .parametric
        case .highShelf: return .highShelf
        case .lowPass:   return .lowPass
        }
    }
}
