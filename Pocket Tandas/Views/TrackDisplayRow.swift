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

import SwiftUI

struct TrackDisplayRow: View {
    let display: TrackDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(display.titleLine)
                .lineLimit(1)
                .truncationMode(.middle)

            if display.hasSecondRow {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(display.artistLine ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let detail = display.detailLine {
                        Text(detail)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    List {
        TrackDisplayRow(display: TrackDisplay(
            metadata: TrackMetadataSnapshot(title: "Poema", artist: "Francisco Canaro",
                                            genre: "Vals", dateText: "1935-05-14", year: 1935, bpm: 120),
            fallback: "poema.mp3"))
        TrackDisplayRow(display: TrackDisplay(filename: "unknown-track.mp3"))
    }
}
