// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  Equalizer.swift
//  Pocket Tandas
//
//  A 3-band parametric EQ on the master bus, built on AVAudioUnitEQ (part of
//  AVFoundation — no third-party dependency, nothing added to the binary). The
//  PlaybackEngine attaches `node` and wires it between the main mixer and the
//  output; this class owns the user-facing band parameters, applies them to the
//  node, and persists them across launches.
//
//  Every band is a `.parametric` peaking filter, so frequency, bandwidth (Q) and
//  gain are all meaningful and adjustable per band. A parametric band at 0 dB
//  gain is mathematically transparent, so the default (flat) preset is inaudible
//  and the EQ can sit enabled-but-flat with no effect until the DJ moves a slider.
//
//  Plain @Observable (not @MainActor) to match the app's other model objects —
//  see the observable-not-mainactor note. All access is from the main thread.
//

import Foundation
import AVFoundation
import Observation

@Observable
final class Equalizer {
    /// One adjustable band. The name and frequency range are fixed metadata; the
    /// three stored values (frequency / bandwidth / gain) are what the user edits.
    struct Band: Identifiable {
        let id: Int                 // index into node.bands
        let name: String
        var frequency: Float        // Hz
        var bandwidth: Float        // octaves — lower is narrower (higher Q)
        var gain: Float             // dB
        let frequencyRange: ClosedRange<Float>
    }

    /// Slider ranges shared by every band.
    static let gainRange: ClosedRange<Float> = -12...12         // dB
    static let bandwidthRange: ClosedRange<Float> = 0.1...3.0   // octaves

    /// Whole-unit on/off. When off the node is bypassed (fully transparent).
    /// Settable only through `setEnabled` so the change reaches the node + disk.
    private(set) var isEnabled: Bool = true

    /// The three bands, low → high. Edited through the `set*` methods so each
    /// change is mirrored to the audio node and persisted.
    private(set) var bands: [Band]

    /// True when the EQ would actually colour the sound — used to badge the EQ
    /// button so the DJ can see at a glance that EQ is in effect.
    var isActive: Bool {
        isEnabled && bands.contains { abs($0.gain) >= 0.1 }
    }

    /// The audio node the PlaybackEngine inserts on the master bus.
    @ObservationIgnored let node = AVAudioUnitEQ(numberOfBands: 3)
    @ObservationIgnored private let defaultsKey = "equalizer.settings.v1"

    init() {
        bands = Self.defaultBands()
        loadPersisted()
        configureNode()
    }

    static func defaultBands() -> [Band] {
        [
            Band(id: 0, name: "Low",  frequency: 120,  bandwidth: 1.5, gain: 0, frequencyRange: 20...1000),
            Band(id: 1, name: "Mid",  frequency: 1000, bandwidth: 1.0, gain: 0, frequencyRange: 100...8000),
            Band(id: 2, name: "High", frequency: 6000, bandwidth: 1.5, gain: 0, frequencyRange: 1000...20000),
        ]
    }

    // MARK: - Editing (from the UI)

    func setEnabled(_ on: Bool) {
        isEnabled = on
        node.bypass = !on
        persist()
    }

    func setGain(_ value: Float, bandID: Int) {
        mutate(bandID) { $0.gain = value.clamped(to: Self.gainRange) }
    }

    func setFrequency(_ value: Float, bandID: Int) {
        mutate(bandID) { band in band.frequency = value.clamped(to: band.frequencyRange) }
    }

    func setBandwidth(_ value: Float, bandID: Int) {
        mutate(bandID) { $0.bandwidth = value.clamped(to: Self.bandwidthRange) }
    }

    /// Restore every band to its factory frequency / bandwidth / gain (flat).
    func reset() {
        bands = Self.defaultBands()
        applyAll()
        persist()
    }

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
        let params = node.bands[band.id]
        params.filterType = .parametric
        params.frequency = band.frequency
        params.bandwidth = band.bandwidth
        params.gain = band.gain
        params.bypass = false
    }

    // MARK: - Persistence (one JSON blob in UserDefaults)

    private struct Snapshot: Codable {
        struct BandState: Codable { var frequency: Float; var bandwidth: Float; var gain: Float }
        var isEnabled: Bool
        var bands: [BandState]
    }

    private func persist() {
        let snapshot = Snapshot(
            isEnabled: isEnabled,
            bands: bands.map { .init(frequency: $0.frequency, bandwidth: $0.bandwidth, gain: $0.gain) })
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
            bands[i].gain = snapshot.bands[i].gain.clamped(to: Self.gainRange)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
