// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EQCurve.swift
//  Pocket Tandas
//
//  The magnitude response of the EQ, for drawing it. AVAudioUnitEQ exposes no
//  coefficients and no response, so the curve is re-derived here from the same
//  (kind, frequency, bandwidth, gain) the node was given.
//
//  Honest caveat: these are RBJ-cookbook biquads, and the SDK describes
//  AVAudioUnitEQ's parametric band as "based on Butterworth analog prototype",
//  not as RBJ. The two agree closely — same family, same definition of bandwidth
//  in octaves — but this is a faithful picture of the filter the DJ asked for
//  rather than a measurement of the one Apple runs. The two passes are exact: the
//  SDK pins them to 2nd-order Butterworth, which is Q = 1/√2.
//
//  Pure maths, no AVFoundation and no SwiftUI, so it can be unit-tested and is
//  cheap enough to recompute inside a Canvas draw on every slider tick.
//

import Foundation

enum EQCurve {
    /// The plotted span — the whole of hearing, and the whole of what the bands
    /// can reach.
    static let minHz: Double = 20
    static let maxHz: Double = 20000

    // MARK: - Response

    /// One band's magnitude response at `hz`, in dB. Zero for a band that is out
    /// of circuit, which is exactly what the node is doing with it.
    static func magnitude(of band: EQBand, at hz: Double, sampleRate: Double) -> Double {
        guard band.isInCircuit, let biquad = Biquad(band: band, sampleRate: sampleRate)
        else { return 0 }
        return biquad.magnitudeDB(at: hz, sampleRate: sampleRate)
    }

    /// The whole unit's response over a log-spaced grid from `minHz` to `maxHz`.
    ///
    /// The bands are a cascade, so their dB responses simply add. Coefficients are
    /// designed once per band rather than once per point — 6 designs and `count`
    /// evaluations, tens of microseconds at the sizes a plot needs.
    static func response(of bands: [EQBand], sampleRate: Double, count: Int) -> [Double] {
        guard count > 1 else { return [] }
        let designs = bands.compactMap { band in
            band.isInCircuit ? Biquad(band: band, sampleRate: sampleRate) : nil
        }
        return (0..<count).map { i in
            let hz = frequency(atPosition: Double(i) / Double(count - 1))
            return designs.reduce(0) { $0 + $1.magnitudeDB(at: hz, sampleRate: sampleRate) }
        }
    }

    // MARK: - The log frequency axis

    /// 0…1 across the plot for a frequency, and back. Musical pitch is
    /// logarithmic, and so is every EQ plot ever drawn.
    static func position(of hz: Double) -> Double {
        let hz = min(max(hz, minHz), maxHz)
        return log2(hz / minHz) / log2(maxHz / minHz)
    }

    static func frequency(atPosition position: Double) -> Double {
        minHz * pow(maxHz / minHz, min(max(position, 0), 1))
    }
}

// MARK: - Biquads

/// One RBJ-cookbook section. Kept `private` because nothing outside wants
/// coefficients — the enum above hands out dB.
private struct Biquad {
    var b0, b1, b2: Double
    var a0, a1, a2: Double

    init?(band: EQBand, sampleRate: Double) {
        guard sampleRate > 0 else { return nil }
        // Away from 0 and from Nyquist, where the bilinear transform's warping
        // degenerates and `sin w0` heads for zero.
        let f0 = min(max(Double(band.frequency), 1), sampleRate * 0.49)
        let w0 = 2 * .pi * f0 / sampleRate
        let cw = cos(w0), sw = sin(w0)

        switch band.kind {
        case .peak:
            let a = pow(10, Double(band.gain) / 40)
            let bw = max(Double(band.bandwidth), 0.01)
            let alpha = sw * sinh(log(2.0) / 2 * bw * w0 / sw)
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a

        case .lowShelf, .highShelf:
            // Slope S = 1, the non-resonant shelf AVAudioUnitEQ gives us.
            let a = pow(10, Double(band.gain) / 40)
            let alpha = sw / 2 * (2.0).squareRoot()
            let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
            if band.kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cw + twoSqrtAAlpha)
                b1 = 2 * a * ((a - 1) - (a + 1) * cw)
                b2 = a * ((a + 1) - (a - 1) * cw - twoSqrtAAlpha)
                a0 = (a + 1) + (a - 1) * cw + twoSqrtAAlpha
                a1 = -2 * ((a - 1) + (a + 1) * cw)
                a2 = (a + 1) + (a - 1) * cw - twoSqrtAAlpha
            } else {
                b0 = a * ((a + 1) + (a - 1) * cw + twoSqrtAAlpha)
                b1 = -2 * a * ((a - 1) + (a + 1) * cw)
                b2 = a * ((a + 1) + (a - 1) * cw - twoSqrtAAlpha)
                a0 = (a + 1) - (a - 1) * cw + twoSqrtAAlpha
                a1 = 2 * ((a - 1) - (a + 1) * cw)
                a2 = (a + 1) - (a - 1) * cw - twoSqrtAAlpha
            }

        case .highPass, .lowPass:
            // 2nd-order Butterworth: Q = 1/√2, −3 dB at the corner, 12 dB/octave.
            let alpha = sw / 2 * (2.0).squareRoot()
            if band.kind == .highPass {
                b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            } else {
                b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            }
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }

        guard a0 != 0 else { return nil }
    }

    /// |H(e^{jω})| in dB.
    func magnitudeDB(at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * .pi * min(hz, sampleRate / 2) / sampleRate
        // z⁻¹ = e^{-jω}, z⁻² = e^{-2jω}
        let c1 = cos(w), s1 = -sin(w)
        let c2 = cos(2 * w), s2 = -sin(2 * w)
        let numR = b0 + b1 * c1 + b2 * c2, numI = b1 * s1 + b2 * s2
        let denR = a0 + a1 * c1 + a2 * c2, denI = a1 * s1 + a2 * s2
        let den = denR * denR + denI * denI
        guard den > 0 else { return 0 }
        let squared = (numR * numR + numI * numI) / den
        guard squared > 0 else { return -120 }
        return max(10 * log10(squared), -120)
    }
}
