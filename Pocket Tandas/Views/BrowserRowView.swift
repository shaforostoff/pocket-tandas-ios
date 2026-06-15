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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isFolder ? .blue : .secondary)
                .frame(width: 24)

            if let metadata, !metadata.isEmpty {
                TrackDisplayRow(display: TrackDisplay(metadata: metadata, fallback: entry.name))
            } else {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if entry.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
