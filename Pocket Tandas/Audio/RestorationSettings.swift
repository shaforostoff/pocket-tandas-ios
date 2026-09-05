// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RestorationSettings.swift
//  Pocket Tandas
//
//  The user-facing settings of the two restoration filters, as Codable Swift
//  values: what the parameters overlays edit, what is persisted, and what is
//  handed to the DSP as `PTDeclickParams` / `PTDehumParams`.
//
//  The ranges and defaults here are the cores' own — see DSP/declick_core.h and
//  DSP/dehum_core.h, where each default is the one the algorithm was calibrated
//  at against real 78 rpm transfers. Keeping them identical is what lets the
//  measurements in those headers describe this port too, so change a default
//  only with a measurement to back it.
//

import Foundation

// MARK: - Declick

/// Autoregressive detect-and-interpolate declicker. See DSP/declick_core.h.
struct DeclickSettings: Codable, Hashable {
    /// 0 = only the most obvious clicks, 1 = aggressive. 0.6 puts the trigger at
    /// 3.9 sigma, which on 78 rpm tango transfers takes impulsive events from
    /// about 71/s to about 14/s.
    var sensitivity: Float = 0.6
    /// How far a detection spreads outwards into its own tail.
    var extent: Float = 0.5
    /// Longest single repair, milliseconds.
    var maxLengthMs: Float = 4.0
    /// 0 subtracts the fraction of each click that adds the least error of its
    /// own; raising it removes more of each click but substitutes more guesswork.
    var depth: Float = 0.0
    /// A second pass catches clicks the first one uncovers. Roughly 50% more CPU.
    var passes: Int = 2
    /// AR model order — the one control where spending CPU clearly buys quality.
    var order: Int = 64
    var dryWet: Float = 1.0

    static let sensitivityRange: ClosedRange<Float> = 0...1
    static let extentRange: ClosedRange<Float> = 0...1
    static let maxLengthRange: ClosedRange<Float> = 0.2...20
    static let depthRange: ClosedRange<Float> = 0...1
    static let passesRange: ClosedRange<Int> = 1...3
    /// 8…256 in eights, matching declick::kMinOrder / kMaxOrder.
    static let orderRange: ClosedRange<Int> = 8...256
    static let orderStep = 8
    static let dryWetRange: ClosedRange<Float> = 0...1

    var coreParams: PTDeclickParams {
        var p = PTDeclickParamsDefault()
        p.sensitivity = sensitivity.clamped(to: Self.sensitivityRange)
        p.extent = extent.clamped(to: Self.extentRange)
        p.maxLengthMs = maxLengthMs.clamped(to: Self.maxLengthRange)
        p.depth = depth.clamped(to: Self.depthRange)
        p.passes = Int32(passes.clamped(to: Self.passesRange))
        p.order = Int32(order.clamped(to: Self.orderRange))
        p.dryWet = dryWet.clamped(to: Self.dryWetRange)
        return p
    }
}

// MARK: - Dehum

/// Narrowband line remover — mains hum, its harmonics, the off-frequency drones
/// speed-corrected disc transfers carry, and (separately) broadband rumble.
/// See DSP/dehum_core.h.
struct DehumSettings: Codable, Hashable {
    /// 0 = only blatant lines, 1 = anything that stands out. 0.5 maps onto a
    /// 16 dB prominence threshold; past about 0.7 hum-free material starts
    /// reaching the activation score.
    var sensitivity: Float = 0.5
    /// Notch 3 dB half width, Hz. 1 Hz at 41 Hz is Q = 20 — a partial 5 Hz away
    /// loses 0.15 dB.
    var bandwidth: Float = 1.0
    /// Top of the automatic search range, Hz. Hum lives low; searching further up
    /// finds sustained musical notes instead.
    var searchTo: Float = 100
    /// Multiples of each line cancelled. Harmonics are a mains-hum idea and cost
    /// music when they are not there, which is why the default is 1.
    var harmonics: Int = 1
    /// 0 = detect automatically, otherwise pin the line here (Hz). Pinning turns
    /// the search — and the track scout — off.
    var frequency: Float = 0
    /// 0 = off, otherwise a high-pass corner (Hz). Rumble is a different defect
    /// from hum but shares the band and dominates some transfers.
    var rumbleHz: Float = 67
    var dryWet: Float = 1.0

    static let sensitivityRange: ClosedRange<Float> = 0...1
    static let bandwidthRange: ClosedRange<Float> = 0.1...5
    static let searchToRange: ClosedRange<Float> = 40...500
    static let harmonicsRange: ClosedRange<Int> = 1...8
    static let frequencyRange: ClosedRange<Float> = 10...500
    static let rumbleRange: ClosedRange<Float> = 10...200
    static let dryWetRange: ClosedRange<Float> = 0...1

    /// True while the line is found by searching rather than pinned by hand —
    /// the only case the track scout has anything to contribute to.
    var isAutomatic: Bool { frequency <= 0 }

    var coreParams: PTDehumParams {
        var p = PTDehumParamsDefault()
        p.sensitivity = sensitivity.clamped(to: Self.sensitivityRange)
        p.bandwidth = bandwidth.clamped(to: Self.bandwidthRange)
        p.searchTo = searchTo.clamped(to: Self.searchToRange)
        p.harmonics = Int32(harmonics.clamped(to: Self.harmonicsRange))
        p.frequency = frequency > 0 ? frequency.clamped(to: Self.frequencyRange) : 0
        p.rumbleHz = rumbleHz > 0 ? rumbleHz.clamped(to: Self.rumbleRange) : 0
        p.dryWet = dryWet.clamped(to: Self.dryWetRange)
        return p
    }
}

// MARK: - Detected lines

/// One narrowband line, as the detector or the scout reports it. The Swift face
/// of `PTDehumLine`, so the views never handle a C struct.
struct DehumLine: Identifiable, Hashable {
    let id: Int
    let frequency: Double
    let detected: Double
    let prominence: Double
    let amplitude: Double
    let coherence: Double
    let viaCoherence: Bool
    let harmonics: Int

    init(id: Int, wire: PTDehumLine) {
        self.id = id
        frequency = wire.frequency
        detected = wire.detected
        prominence = wire.prominence
        amplitude = wire.amplitude
        coherence = wire.coherence
        viaCoherence = wire.viaCoherence != 0
        harmonics = Int(wire.harmonics)
    }

    var wire: PTDehumLine {
        PTDehumLine(frequency: frequency, detected: detected, prominence: prominence,
                    amplitude: amplitude, coherence: coherence,
                    viaCoherence: viaCoherence ? 1 : 0, harmonics: Int32(harmonics))
    }

    /// How it was found: prominence above the local baseline, or coherence —
    /// the phase-based route for lines that sit down in the rumble where a
    /// magnitude spectrum cannot separate them from it.
    var routeLabel: String { viaCoherence ? "coherence" : "prominence" }
}
