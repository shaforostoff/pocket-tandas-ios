// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueRowView.swift
//  Pocket Tandas
//
//  One row in the play queue. Reuses the shared TrackDisplay layout and shows a
//  playing / fading indicator for the current track.
//

import SwiftUI

struct QueueRowView: View {
    let item: QueueItem
    var metadata: TrackMetadataSnapshot?
    let isCurrent: Bool
    let isFading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            TrackDisplayRow(display: display)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var display: TrackDisplay {
        if let metadata, !metadata.isEmpty {
            return TrackDisplay(metadata: metadata, fallback: item.filename)
        }
        return TrackDisplay(filename: item.filename)
    }

    private var icon: String {
        guard isCurrent else { return "music.note" }
        return isFading ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }
}
