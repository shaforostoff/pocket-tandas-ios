// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  BrowserRowView.swift
//  Pocket Tandas
//
//  One row in the file browser. Shows filename for now; rich metadata display
//  (title / artist · BPM · genre · date) is wired in M7 via TrackDisplay.
//

import SwiftUI

struct BrowserRowView: View {
    let entry: LibraryEntry
    var metadata: TrackMetadataSnapshot?
    /// True for the audio file currently being auditioned (Explore prelistening) —
    /// swaps in a speaker icon and an accent tint so it's easy to spot.
    var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : entry.systemImage)
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint)
                                           : AnyShapeStyle(entry.isFolder ? Color.blue : Color.secondary))
                .frame(width: 24)

            if let metadata, !metadata.isEmpty {
                // Greedy layout: let it fill the row so its right-aligned detail
                // (BPM/genre/date) sits at the trailing edge rather than mid-row.
                // Audio rows are never navigable, so no chevron follows.
                TrackDisplayRow(display: TrackDisplay(metadata: metadata, fallback: entry.name))
            } else {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            if entry.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
