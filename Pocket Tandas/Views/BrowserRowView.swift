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
    let title: String
    let systemImage: String
    let isNavigable: Bool
    /// Tints the leading icon blue (matches the file browser's folder rows).
    let isContainer: Bool
    var metadata: TrackMetadataSnapshot?
    /// True for the row currently being auditioned (Explore prelistening) — swaps
    /// in a speaker icon and an accent tint so it's easy to spot.
    var isPlaying: Bool = false

    /// File browser row.
    init(entry: LibraryEntry, metadata: TrackMetadataSnapshot? = nil, isPlaying: Bool = false) {
        self.init(title: entry.name, systemImage: entry.systemImage, isNavigable: entry.isNavigable,
                  isContainer: entry.isFolder, metadata: metadata, isPlaying: isPlaying)
    }

    /// Value-based row, shared by the Music-library browser.
    init(title: String, systemImage: String, isNavigable: Bool, isContainer: Bool,
         metadata: TrackMetadataSnapshot? = nil, isPlaying: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isNavigable = isNavigable
        self.isContainer = isContainer
        self.metadata = metadata
        self.isPlaying = isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : systemImage)
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint)
                                           : AnyShapeStyle(isContainer ? Color.blue : Color.secondary))
                .frame(width: 24)

            if let metadata, !metadata.isEmpty {
                // Greedy layout: let it fill the row so its right-aligned detail
                // (BPM/genre/date) sits at the trailing edge rather than mid-row.
                // Audio rows are never navigable, so no chevron follows.
                TrackDisplayRow(display: TrackDisplay(metadata: metadata, fallback: title))
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            if isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
