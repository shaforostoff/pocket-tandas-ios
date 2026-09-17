// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackDisplayRow.swift
//  Pocket Tandas
//
//  The shared two-line metadata layout (title; artist + BPM/genre/date).
//
//  Fields the analyser measured, because the file's tags had none, are drawn in
//  a blue rather than the grey of the rest of the line — so a BPM that came out
//  of the audio is never mistaken for one the collection actually carries.
//

import SwiftUI

struct TrackDisplayRow: View {
    let display: TrackDisplay
    /// Optional text shown at the top-right of the title row (e.g. the playing
    /// track's remaining time, "-0:50").
    var titleAccessory: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(display.titleLine)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let titleAccessory {
                    Spacer(minLength: 8)
                    Text(titleAccessory)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if display.hasSecondRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(display.artistLine ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if !display.detailParts.isEmpty {
                        detailText
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The detail line as a single Text built by concatenation, rather than an
    /// HStack of one Text per field: it has to truncate, align and share a
    /// baseline as one run, which separate views would not. A tint set on a run
    /// this way overrides the `.secondary` style the whole line is drawn in.
    private var detailText: Text {
        var line = Text(verbatim: "")
        for (index, part) in display.detailParts.enumerated() {
            if index > 0 { line = line + Text(verbatim: " · ") }
            line = line + (part.isEstimated ? Text(part.text).foregroundStyle(measuredTint)
                                            : Text(part.text))
        }
        return line
    }

    /// Tint for a value the app measured rather than read from the file's tags.
    ///
    /// Dark blue on a light row, pale blue on a dark one: one value cannot serve
    /// both, as the dark blue all but disappears against a dark background. Both
    /// sit a little quieter than the accent colour, which in these same rows
    /// means an action or a state (the playing track, the insert anchor) — a
    /// measured BPM is neither, it is just a fact with a caveat.
    private var measuredTint: Color {
        colorScheme == .dark ? Color(red: 0.55, green: 0.75, blue: 1.00)
                             : Color(red: 0.11, green: 0.31, blue: 0.68)
    }
}

#Preview {
    List {
        // Fully tagged: nothing tinted.
        TrackDisplayRow(display: TrackDisplay(
            metadata: TrackMetadataSnapshot(title: "Poema", artist: "Francisco Canaro",
                                            taggedGenre: "Vals", dateText: "1935-05-14", year: 1935,
                                            taggedBPM: 120),
            fallback: "poema.mp3"))
        // Untagged: both measured fields tinted, the date beside them left grey.
        TrackDisplayRow(display: TrackDisplay(
            metadata: TrackMetadataSnapshot(title: "Maragata", artist: "Aníbal Troilo",
                                            dateText: "1941", year: 1941,
                                            estimatedBPM: 127.86, estimatedGenre: "Tango"),
            fallback: "maragata.m4a"))
        // One of each: the tagged BPM stays grey, the measured genre does not.
        TrackDisplayRow(display: TrackDisplay(
            metadata: TrackMetadataSnapshot(title: "Nueve de Julio", artist: "Juan D'Arienzo",
                                            taggedBPM: 132, estimatedGenre: "Milonga"),
            fallback: "nueve.mp3"))
        TrackDisplayRow(display: TrackDisplay(filename: "unknown-track.mp3"))
    }
}
