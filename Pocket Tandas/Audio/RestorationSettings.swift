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
//  These are also wire types: in Remote Control mode the sender edits the
//  RECEIVER's filters, and a whole settings struct crosses the link per edit —
//  so, like TrackAddRequest, every one of them decodes a missing key to its
//  default rather than failing, and a peer on an older build still understands
//  the message.
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 0.6
        extent = try c.decodeIfPresent(Float.self, forKey: .extent) ?? 0.5
        maxLengthMs = try c.decodeIfPresent(Float.self, forKey: .maxLengthMs) ?? 4.0
        depth = try c.decodeIfPresent(Float.self, forKey: .depth) ?? 0
        passes = try c.decodeIfPresent(Int.self, forKey: .passes) ?? 2
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 64
        dryWet = try c.decodeIfPresent(Float.self, forKey: .dryWet) ?? 1
    }

    static let sensitivityRange: ClosedRange<Float> = 0...1
    static let extentRange: ClosedRange<Float> = 0...1
    static let maxLengthRange: ClosedRange<Float> = 0.2...20
    static let depthRange: ClosedRange<Float> = 0...1
    static let passesRange: ClosedRange<Int> = 1...3
    /// 8…256 in eights, matching declick::kMinOrder / kMaxOrder.
    static let orderRange: ClosedRange<Int> = 8...256
    static let orderStep = 8
    static let dryWetRange: ClosedRange<Float> = 0...1

    /// Every field inside its range. Applied to each edit — which matters most for
    /// one that arrived over the peer link, where the values were composed by
    /// another device and there is no slider to have bounded them.
    func sanitized() -> DeclickSettings {
        var s = self
        s.sensitivity = sensitivity.clamped(to: Self.sensitivityRange)
        s.extent = extent.clamped(to: Self.extentRange)
        s.maxLengthMs = maxLengthMs.clamped(to: Self.maxLengthRange)
        s.depth = depth.clamped(to: Self.depthRange)
        s.passes = passes.clamped(to: Self.passesRange)
        // The core keeps the order even and in eights; so does the stepper, and so
        // must anything that arrives already made up.
        s.order = (order.clamped(to: Self.orderRange) / Self.orderStep) * Self.orderStep
        if s.order < Self.orderRange.lowerBound { s.order = Self.orderRange.lowerBound }
        s.dryWet = dryWet.clamped(to: Self.dryWetRange)
        return s
    }

    var coreParams: PTDeclickParams {
        let s = sanitized()
        var p = PTDeclickParamsDefault()
        p.sensitivity = s.sensitivity
        p.extent = s.extent
        p.maxLengthMs = s.maxLengthMs
        p.depth = s.depth
        p.passes = Int32(s.passes)
        p.order = Int32(s.order)
        p.dryWet = s.dryWet
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sensitivity = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 0.5
        bandwidth = try c.decodeIfPresent(Float.self, forKey: .bandwidth) ?? 1
        searchTo = try c.decodeIfPresent(Float.self, forKey: .searchTo) ?? 100
        harmonics = try c.decodeIfPresent(Int.self, forKey: .harmonics) ?? 1
        frequency = try c.decodeIfPresent(Float.self, forKey: .frequency) ?? 0
        rumbleHz = try c.decodeIfPresent(Float.self, forKey: .rumbleHz) ?? 67
        dryWet = try c.decodeIfPresent(Float.self, forKey: .dryWet) ?? 1
    }

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

    /// Every field inside its range — see DeclickSettings.sanitized(). The two
    /// controls with an "off" position keep it: zero passes through rather than
    /// being clamped up to the bottom of the range.
    func sanitized() -> DehumSettings {
        var s = self
        s.sensitivity = sensitivity.clamped(to: Self.sensitivityRange)
        s.bandwidth = bandwidth.clamped(to: Self.bandwidthRange)
        s.searchTo = searchTo.clamped(to: Self.searchToRange)
        s.harmonics = harmonics.clamped(to: Self.harmonicsRange)
        s.frequency = frequency > 0 ? frequency.clamped(to: Self.frequencyRange) : 0
        s.rumbleHz = rumbleHz > 0 ? rumbleHz.clamped(to: Self.rumbleRange) : 0
        s.dryWet = dryWet.clamped(to: Self.dryWetRange)
        return s
    }

    var coreParams: PTDehumParams {
        let s = sanitized()
        var p = PTDehumParamsDefault()
        p.sensitivity = s.sensitivity
        p.bandwidth = s.bandwidth
        p.searchTo = s.searchTo
        p.harmonics = Int32(s.harmonics)
        p.frequency = s.frequency
        p.rumbleHz = s.rumbleHz
        p.dryWet = s.dryWet
        return p
    }
}

// MARK: - Detected lines

/// One narrowband line, as the detector or the scout reports it. The Swift face
/// of `PTDehumLine`, so the views never handle a C struct.
struct DehumLine: Identifiable, Hashable, Codable {
    let id: Int
    let frequency: Double
    let detected: Double
    let prominence: Double
    let amplitude: Double
    let coherence: Double
    let viaCoherence: Bool
    let harmonics: Int

    init(id: Int, frequency: Double, detected: Double, prominence: Double,
         amplitude: Double, coherence: Double, viaCoherence: Bool, harmonics: Int) {
        self.id = id
        self.frequency = frequency
        self.detected = detected
        self.prominence = prominence
        self.amplitude = amplitude
        self.coherence = coherence
        self.viaCoherence = viaCoherence
        self.harmonics = harmonics
    }

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

// MARK: - Background analysis

/// How far the per-track background analysis has got. The phase alone, with no
/// payload, because the lines it found reach the panel through
/// `RestorationControlling.detectedLines` — which is where the live detector's
/// lines come from too, so the panel shows the same thing whether it is driving
/// this device or a receiver across the room.
enum RestorationScoutPhase: String, Codable {
    /// Nothing playing.
    case idle
    /// Reading the opening of the track.
    case scanning
    /// Read it, and there was nothing steady enough to remove.
    case foundNothing
    /// Read it and found something.
    case found
    /// Not attempted: no readable asset, or the frequency is pinned by hand.
    case skipped
}
