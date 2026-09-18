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
//  The band table is modelled on El Espejero's "EQ 4 TJ" — the four working
//  controls of a shellac-era transfer (bass, reverb, brilliance, hiss) between two
//  rails that are set once and left alone (ultra-low mud, and the artifact region
//  above 10 kHz). Each band therefore has a FIXED KIND, and the kind decides which
//  knobs exist: a high pass has only a corner frequency, a shelf has frequency and
//  gain, a peaking band has frequency, gain and Q. That is the shape of the SSL
//  channel strip the article holds up as the ideal tool for the job.
//
//  `RestorationControlling` is the third of the same shape, for the two disc
//  restoration filters — implemented by `RestorationFilters` (local) and by
//  `RemoteAudioControl` (forwards each edit to the receiver).
//

import Foundation

/// What one band DOES, which fixes which of its knobs are meaningful.
///
/// The names are the article's, not the filter designer's: the DJ is choosing
/// between "reverb" and "hiss", and only incidentally between a peak and a shelf.
enum EQBandKind: String, Codable, Hashable {
    case highPass       // Low Cut — ultra-low mud
    case lowShelf       // Bass
    case peak           // Reverb Cut, Brilliance
    case highShelf      // Hiss Cut
    case lowPass        // High Cut — mp3 / transfer artifacts

    /// Shelves and peaks are boost/cut controls; the two cuts are switched in or
    /// out instead, because there is no gain position at which they do nothing.
    var hasGain: Bool { self != .highPass && self != .lowPass }
    /// Only the two peaking bands take a width. AVAudioUnitEQ's non-resonant
    /// shelves and its Butterworth high/low pass have a fixed slope.
    var hasQ: Bool { self == .peak }
    /// True for the two rails, which carry an on/off switch rather than a gain.
    var isCut: Bool { self == .highPass || self == .lowPass }
}

/// One adjustable band. The id, name, kind, caption and Hz bounds are fixed
/// metadata; frequency / bandwidth / gain / isEnabled are what the user edits.
///
/// The Hz bounds are stored as two Floats rather than a `ClosedRange` so the
/// Codable conformance is plain and version-tolerant on the wire.
struct EQBand: Identifiable, Codable, Hashable {
    let id: Int                 // index into AVAudioUnitEQ.bands
    let name: String
    let kind: EQBandKind
    /// One line on what the band is for, shown under its heading in the panel.
    let caption: String
    var frequency: Float        // Hz
    var bandwidth: Float        // octaves — lower is narrower (higher Q)
    var gain: Float             // dB
    /// Whether the filter is in circuit. Only the two cut kinds expose this; the
    /// gain bands are transparent at 0 dB and stay nominally enabled.
    var isEnabled: Bool
    let minFrequency: Float
    let maxFrequency: Float

    var frequencyRange: ClosedRange<Float> { minFrequency...maxFrequency }

    /// `bandwidth` expressed the way every EQ plugin labels it. Q is what the
    /// panel shows and octaves is what AVAudioUnitEQ wants, so the stored value
    /// stays in octaves and this is the view onto it — see EQBandwidth.
    var q: Float { EQBandwidth.q(forOctaves: bandwidth) }

    /// True when the band changes the signal at all. This is what decides whether
    /// the node actually runs the filter: a peaking or shelving band at 0 dB is
    /// mathematically transparent, so bypassing it is both free CPU and inaudible.
    var isInCircuit: Bool {
        kind.isCut ? isEnabled : abs(gain) >= 0.05
    }

    /// True when the band is COLOURING the sound — what badges the EQ button.
    ///
    /// Deliberately narrower than `isInCircuit`: the two rails are set once and
    /// forgotten (the article's §0 and §4′), so a low cut sitting at its default
    /// corner is not "the DJ is EQ-ing this record" and should not light the badge.
    var isColouring: Bool {
        switch kind {
        case .highPass: return isEnabled && frequency > Self.railLowCutCorner
        case .lowPass:  return isEnabled
        default:        return abs(gain) >= 0.1
        }
    }

    /// Above this corner a low cut is doing more than protecting the speakers.
    private static let railLowCutCorner: Float = 40

    init(id: Int, name: String, kind: EQBandKind, caption: String = "",
         frequency: Float, bandwidth: Float = 1.0, gain: Float = 0,
         isEnabled: Bool = true, frequencyRange: ClosedRange<Float>) {
        self.id = id
        self.name = name
        self.kind = kind
        self.caption = caption
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.gain = gain
        self.isEnabled = isEnabled
        self.minFrequency = frequencyRange.lowerBound
        self.maxFrequency = frequencyRange.upperBound
    }

    /// Version-tolerant like RemoteAudioSettings: `kind`, `caption` and
    /// `isEnabled` arrived after the three-band EQ, so a peer on an older build
    /// sends a band without them and it still decodes — as a plain peaking band,
    /// which is what every band used to be.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(EQBandKind.self, forKey: .kind) ?? .peak
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        frequency = try c.decodeIfPresent(Float.self, forKey: .frequency) ?? 1000
        bandwidth = try c.decodeIfPresent(Float.self, forKey: .bandwidth) ?? 1.0
        gain = try c.decodeIfPresent(Float.self, forKey: .gain) ?? 0
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        minFrequency = try c.decodeIfPresent(Float.self, forKey: .minFrequency) ?? 20
        maxFrequency = try c.decodeIfPresent(Float.self, forKey: .maxFrequency) ?? 20000
    }
}

/// Q ↔ bandwidth-in-octaves, the RBJ cookbook relation.
///
/// AVAudioUnitEQ takes a band's width in octaves and the wire carries octaves, but
/// every EQ a DJ has ever touched labels that control Q — so the conversion lives
/// here and only the panel sees Q. The mapping is an exact bijection, so a value
/// shown as Q and stored as octaves round-trips without drift.
enum EQBandwidth {
    /// The Q range the panel's slider offers.
    ///
    /// The low end is exactly the image of the widest band the model allows
    /// (Equalizer.bandwidthRange's 3 octaves), so the slider's left stop and the
    /// clamp behind it agree rather than fighting. The high end stops well short
    /// of the model's 0.1 octaves — that is a surgical notch, and none of these
    /// four controls is for surgery.
    static let qRange: ClosedRange<Float> = q(forOctaves: 3.0)...8.0

    static func q(forOctaves bandwidth: Float) -> Float {
        // Floored above zero so `t` is always > 1 and the division is safe —
        // and so this can't reach back into `qRange`, which is initialised from it.
        let t = pow(2.0, Double(max(bandwidth, 0.001)))
        return Float(t.squareRoot() / (t - 1))
    }

    static func octaves(forQ q: Float) -> Float {
        let q = Double(max(q, 0.001))
        let x = 1 + 1 / (2 * q * q)
        return Float(log2(x + (x * x - 1).squareRoot()))
    }
}

/// The three starting points the article prescribes.
///
/// `flat` is the old "Reset to Flat" — every gain at zero, only the ultra-low rail
/// in. `goldenAge` is the curve the article builds up over its worked example, for
/// electrical shellac from 1926–49. `post1950` is its closing note: tape-mastered
/// and RIAA records want a flat EQ, and nothing above 8 kHz can be cut without
/// taking the music with it.
enum EQPreset: String, Codable, CaseIterable, Identifiable {
    case flat, goldenAge, post1950

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat:      return "Flat"
        case .goldenAge: return "Golden Age"
        case .post1950:  return "Post-1950"
        }
    }

    var detail: String {
        switch self {
        case .flat:      return "Every band at zero"
        case .goldenAge: return "Shellac, 1926–49"
        case .post1950:  return "Tape and vinyl"
        }
    }
}

/// Everything the EQ panel needs. Implemented natively by `Equalizer` (local) and
/// by `RemoteAudioControl` (forwards each edit to the receiver).
protocol EqualizerControlling {
    var isEnabled: Bool { get }
    var bands: [EQBand] { get }
    /// True when the EQ would actually colour the sound — badges the EQ button.
    var isActive: Bool { get }
    /// The rate the chain renders at, which the response curve needs: a digital
    /// filter's shape depends on it, and visibly so near the top of the band.
    var sampleRate: Double { get }
    func setEnabled(_ on: Bool)
    func setGain(_ value: Float, bandID: Int)
    func setFrequency(_ value: Float, bandID: Int)
    func setBandwidth(_ value: Float, bandID: Int)
    /// Switches one of the two cut filters in or out. A no-op on a gain band.
    func setBandEnabled(_ on: Bool, bandID: Int)
    func apply(_ preset: EQPreset)
    func reset()
}

extension EqualizerControlling {
    /// A remote panel draws its curve from the receiver's band values but has no
    /// reason to learn the receiver's output rate: the difference between 44.1 and
    /// 48 kHz is a hair at the very top of the plot, so the wire stays as it is.
    var sampleRate: Double { 44100 }
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
