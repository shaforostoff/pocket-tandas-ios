// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioControlling.swift
//  Pocket Tandas
//
//  The EQ / volume counterparts of PlaybackControlling: they let one set of views
//  (EQButton + EqualizerView, VolumeButton + VolumeView) drive either the local
//  audio chain (Equalizer / PlaybackEngine) or, in Remote Control mode, the
//  receiver's chain through RemoteAudioControl.
//
//  `EQBand` is the single band description shared by all three: the local
//  Equalizer's stored state, the sliders' bounds, and the wire payload the
//  receiver broadcasts to the sender.
//

import Foundation

/// One adjustable parametric band. The id, name and Hz bounds are fixed metadata;
/// frequency / bandwidth / gain are what the user edits.
///
/// The Hz bounds are stored as two Floats rather than a `ClosedRange` so the
/// Codable conformance is plain and version-tolerant on the wire.
struct EQBand: Identifiable, Codable, Hashable {
    let id: Int                 // index into AVAudioUnitEQ.bands
    let name: String
    var frequency: Float        // Hz
    var bandwidth: Float        // octaves — lower is narrower (higher Q)
    var gain: Float             // dB
    let minFrequency: Float
    let maxFrequency: Float

    var frequencyRange: ClosedRange<Float> { minFrequency...maxFrequency }

    init(id: Int, name: String, frequency: Float, bandwidth: Float, gain: Float,
         frequencyRange: ClosedRange<Float>) {
        self.id = id
        self.name = name
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.gain = gain
        self.minFrequency = frequencyRange.lowerBound
        self.maxFrequency = frequencyRange.upperBound
    }
}

/// Everything the EQ panel needs. Implemented natively by `Equalizer` (local) and
/// by `RemoteAudioControl` (forwards each edit to the receiver).
protocol EqualizerControlling {
    var isEnabled: Bool { get }
    var bands: [EQBand] { get }
    /// True when the EQ would actually colour the sound — badges the EQ button.
    var isActive: Bool { get }
    func setEnabled(_ on: Bool)
    func setGain(_ value: Float, bandID: Int)
    func setFrequency(_ value: Float, bandID: Int)
    func setBandwidth(_ value: Float, bandID: Int)
    func reset()
}

/// Master output level, 0…1. Implemented by `PlaybackEngine` (local) and by
/// `RemoteAudioControl` (forwards to the receiver).
protocol VolumeControlling {
    var masterVolume: Float { get }
    func setMasterVolume(_ value: Float)
}

extension VolumeControlling {
    /// Full-scale within a hair — used to decide whether the volume is attenuated.
    var isAttenuated: Bool { masterVolume < 0.995 }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
