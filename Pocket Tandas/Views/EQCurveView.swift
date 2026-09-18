// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EQCurveView.swift
//  Pocket Tandas
//
//  The EQ's response, drawn. Log frequency across, dB up, the summed curve of
//  whatever the six bands are currently doing — redrawn live as a slider moves,
//  which is the whole point: the article's technique is about the SHAPE (the two
//  "scissors", the dip at 1 kHz), and a column of sliders never shows a shape.
//
//  Read-only. Tapping a band's marker selects it, and the panel below highlights
//  that band's controls; editing still happens on the sliders, where a value can
//  be set precisely with a thumb in the way.
//
//  Numbers come from EQCurve; this file is only paint.
//

import SwiftUI

struct EQCurveView: View {
    let bands: [EQBand]
    let sampleRate: Double
    @Binding var selection: Int?
    /// Whole-unit enable. When off the curve is drawn faint — it still says what
    /// the settings are, but not that they are being heard.
    var isEQEnabled: Bool = true

    /// ±15 dB: a little more than the ±12 the gain sliders reach, so a boosted
    /// band doesn't touch the ceiling. Steeper things (the two passes) run off the
    /// bottom, which is honest — they are meant to.
    private static let dBSpan: Double = 15
    private static let gridHz: [Double] = [30, 100, 300, 1000, 3000, 10000]
    private static let gridDB: [Double] = [-12, -6, 6, 12]
    /// Enough points that the steepest thing on the plot — a 12 dB/octave pass —
    /// draws smooth, and few enough to redraw on every tick of a slider drag.
    private static let sampleCount = 220
    private static let markerRadius: CGFloat = 4.5

    var body: some View {
        GeometryReader { geo in
            Canvas(opaque: false) { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in select(near: location, in: geo.size) }
        }
        .frame(height: 150)
        .accessibilityElement()
        .accessibilityLabel("Equalizer response curve")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Geometry

    /// Room at the bottom for the frequency scale, and a hair at the top so a
    /// +12 dB marker isn't clipped by the sheet's edge.
    private func plot(in size: CGSize) -> CGRect {
        CGRect(x: 6, y: 8, width: max(size.width - 12, 1), height: max(size.height - 26, 1))
    }

    private func x(_ hz: Double, in rect: CGRect) -> CGFloat {
        rect.minX + rect.width * EQCurve.position(of: hz)
    }

    private func y(_ dB: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(dB, -Self.dBSpan * 2), Self.dBSpan * 2)
        return rect.midY - rect.height / 2 * CGFloat(clamped / Self.dBSpan)
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize) {
        let rect = plot(in: size)
        drawGrid(in: context, rect: rect)

        let response = EQCurve.response(of: bands, sampleRate: sampleRate,
                                        count: Self.sampleCount)
        guard response.count == Self.sampleCount else { return }

        var curve = Path()
        for (i, dB) in response.enumerated() {
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(i) / CGFloat(Self.sampleCount - 1),
                y: y(dB, in: rect))
            i == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }

        // The band between the curve and 0 dB, so boost and cut read at a glance.
        var shaded = curve
        shaded.addLine(to: CGPoint(x: rect.maxX, y: y(0, in: rect)))
        shaded.addLine(to: CGPoint(x: rect.minX, y: y(0, in: rect)))
        shaded.closeSubpath()

        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.fill(shaded, with: .color(.accentColor.opacity(isEQEnabled ? 0.16 : 0.06)))
        clipped.stroke(curve, with: .color(.accentColor.opacity(isEQEnabled ? 1 : 0.35)),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        drawMarkers(in: context, rect: rect, response: response)
    }

    private func drawGrid(in context: GraphicsContext, rect: CGRect) {
        for hz in Self.gridHz {
            let px = x(hz, in: rect)
            context.stroke(Path { $0.move(to: CGPoint(x: px, y: rect.minY))
                                  $0.addLine(to: CGPoint(x: px, y: rect.maxY)) },
                           with: .color(.primary.opacity(0.08)), lineWidth: 1)
            context.draw(Text(label(hz)).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: px, y: rect.maxY + 3), anchor: .top)
        }
        for dB in Self.gridDB {
            let py = y(dB, in: rect)
            context.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: py))
                                  $0.addLine(to: CGPoint(x: rect.maxX, y: py)) },
                           with: .color(.primary.opacity(0.07)), lineWidth: 1)
            // The technique is about specific amounts — "a few dB down at 1 kHz",
            // "+6 on the bass" — so the vertical scale has to be readable, not
            // just present. Only the extremes are labelled; more would be clutter.
            guard abs(dB) == 12 else { continue }
            context.draw(
                Text(dB > 0 ? "+12" : "−12").font(.system(size: 8))
                    .foregroundStyle(.tertiary),
                at: CGPoint(x: rect.minX + 2, y: py - 1), anchor: .bottomLeading)
        }
        let zero = y(0, in: rect)
        context.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: zero))
                              $0.addLine(to: CGPoint(x: rect.maxX, y: zero)) },
                       with: .color(.primary.opacity(0.22)), lineWidth: 1)
    }

    /// A dot per band, sitting on the curve at its own frequency. The selected one
    /// is filled and named; naming all six would collide — Hiss Cut and High Cut
    /// are only a few per cent of the axis apart.
    private func drawMarkers(in context: GraphicsContext, rect: CGRect,
                             response: [Double]) {
        for band in bands {
            let hz = Double(band.frequency)
            let px = x(hz, in: rect)
            // Kept inside the plot: a Hiss Cut at −12 dB under a High Cut runs off
            // the bottom of the scale, and a marker drawn there would land on the
            // frequency labels.
            let py = y(sampled(response, at: hz), in: rect)
                .clamped(to: (rect.minY + Self.markerRadius)...(rect.maxY - Self.markerRadius))
            let dot = Path(ellipseIn: CGRect(
                x: px - Self.markerRadius, y: py - Self.markerRadius,
                width: Self.markerRadius * 2, height: Self.markerRadius * 2))
            let live = band.isInCircuit && isEQEnabled

            if band.id == selection {
                context.fill(dot, with: .color(.accentColor))
                context.stroke(dot, with: .style(.background), lineWidth: 1.5)
                context.draw(
                    Text(band.name).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary),
                    at: CGPoint(x: min(max(px, rect.minX + 28), rect.maxX - 28),
                                y: max(py - 12, rect.minY + 6)),
                    anchor: .bottom)
            } else {
                context.fill(dot, with: .style(.background))
                context.stroke(dot, with: .color(.accentColor.opacity(live ? 0.8 : 0.3)),
                               lineWidth: 1.5)
            }
        }
    }

    /// The summed response at an arbitrary frequency, read off the grid that was
    /// already computed rather than designing the six filters a second time.
    private func sampled(_ response: [Double], at hz: Double) -> Double {
        let position = EQCurve.position(of: hz) * Double(response.count - 1)
        let low = Int(position.rounded(.down)).clamped(to: 0...(response.count - 1))
        let high = min(low + 1, response.count - 1)
        let t = position - Double(low)
        return response[low] * (1 - t) + response[high] * t
    }

    // MARK: - Selection

    private func select(near location: CGPoint, in size: CGSize) {
        let rect = plot(in: size)
        // Nearest in x only: the markers are well separated horizontally and the
        // dots are small targets for a thumb.
        let nearest = bands.min {
            abs(x(Double($0.frequency), in: rect) - location.x)
                < abs(x(Double($1.frequency), in: rect) - location.x)
        }
        guard let nearest,
              abs(x(Double(nearest.frequency), in: rect) - location.x) < 32 else {
            selection = nil
            return
        }
        selection = nearest.id == selection ? nil : nearest.id
    }

    // MARK: - Labels

    private func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }

    private var accessibilitySummary: String {
        let active = bands.filter(\.isColouring)
        guard isEQEnabled, !active.isEmpty else { return "Flat" }
        return active.map { band in
            band.kind.hasGain
                ? "\(band.name) \(String(format: "%+.0f", band.gain)) decibels"
                : "\(band.name) at \(Int(band.frequency)) hertz"
        }.joined(separator: ", ")
    }
}
