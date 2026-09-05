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
//  `RestorationControlling` is the third of the same shape, for the two disc
//  restoration filters — implemented by `RestorationFilters` (local) and by
//  `RemoteAudioControl` (forwards each edit to the receiver).
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

/// Everything the restoration panel needs: the two filters' switches, their
/// parameters, and what the hum detector currently holds.
///
/// A parameter edit is expressed as a mutation of the whole settings struct
/// rather than as one setter per control. Locally that is just convenience; over
/// the link it is what keeps the two ends in step, for the same reason an EQ band
/// edit carries all three of its parameters — a dropped intermediate value cannot
/// leave the sender and the receiver disagreeing about the filter.
protocol RestorationControlling: AnyObject {
    var declickEnabled: Bool { get }
    var dehumEnabled: Bool { get }
    var declick: DeclickSettings { get }
    var dehum: DehumSettings { get }

    /// The narrowband lines being cancelled right now, for the Detected list.
    var detectedLines: [DehumLine] { get }
    /// How far the per-track background analysis has got.
    var scoutPhase: RestorationScoutPhase { get }

    /// True when either filter is in circuit — badges the EQ button. Named apart
    /// from `EqualizerControlling.isActive` because RemoteAudioControl is both,
    /// and the button wants to know which of the two is doing something.
    var isRestorationActive: Bool { get }
    /// The delay the declicker imposes, in seconds, at the current settings.
    var declickLatency: TimeInterval { get }

    func setDeclickEnabled(_ on: Bool)
    func setDehumEnabled(_ on: Bool)
    func updateDeclick(_ change: (inout DeclickSettings) -> Void)
    func updateDehum(_ change: (inout DehumSettings) -> Void)
    func resetDeclick()
    func resetDehum()
}

/// Master output level, 0…1. Implemented by `PlaybackEngine` (local) and by
/// `RemoteAudioControl` (forwards to the receiver).
///
/// The value is a FADER POSITION, not an amplitude — see VolumeTaper.
protocol VolumeControlling {
    var masterVolume: Float { get }
    func setMasterVolume(_ value: Float)
}

/// Fader position (0…1) → the linear amplitude the mixer wants.
///
/// Loudness is perceived roughly logarithmically, so a fader that passes its
/// position straight through wastes its top half: position 0.5 is only −6 dB,
/// which barely reads as quieter. A cubic taper spreads the audible range over the
/// whole travel — half-way is −18 dB, and the top of the slider still gives fine
/// control where a DJ actually works.
enum VolumeTaper {
    static func amplitude(for position: Float) -> Float {
        let p = position.clamped(to: 0...1)
        return p * p * p
    }

    /// Attenuation in dB for display, or nil at silence.
    static func decibels(for position: Float) -> Float? {
        let amplitude = amplitude(for: position)
        guard amplitude > 0 else { return nil }
        return 20 * log10(amplitude)
    }
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
