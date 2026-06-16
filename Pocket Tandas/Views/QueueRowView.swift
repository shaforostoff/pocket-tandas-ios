// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueRowView.swift
//  Pocket Tandas
//
//  One row in the play queue. Reuses the shared TrackDisplay layout and shows a
//  playing / fading indicator for the current track. For the current track it
//  also shows a live countdown ("-0:50") and a progress-bar-like fill behind the
//  row that advances with playback.
//
//  Playback position isn't an observable property, so the current row ticks via
//  a TimelineView (~4 Hz). The progress fill lives in the row *content* (not in
//  .listRowBackground, which a List doesn't re-render on a timeline tick) and is
//  made full-width by zeroing the row insets in QueueView.
//

import SwiftUI

struct QueueRowView: View {
    let item: QueueItem
    var metadata: TrackMetadataSnapshot?
    let isCurrent: Bool
    let isFading: Bool
    /// When true this row is the insert anchor: a marker line is drawn above it
    /// to show that newly added tracks land here.
    let isAnchor: Bool
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        if isCurrent {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                row(remaining: remainingText, progress: fraction)
            }
        } else {
            row(remaining: nil, progress: nil)
        }
    }

    @ViewBuilder
    private func row(remaining: String?, progress: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAnchor { anchorMarker }
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                TrackDisplayRow(display: display, titleAccessory: remaining)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(alignment: .leading) {
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.accentColor.opacity(0.10)              // whole track
                            Color.accentColor.opacity(0.28)              // played portion
                                .frame(width: geo.size.width * progress)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// The insert-anchor marker: a labelled accent line above the row, marking
    /// where newly added tracks will be inserted.
    private var anchorMarker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Insert here", systemImage: "arrow.down.to.line")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Played fraction (0...1) of the current track.
    private var fraction: CGFloat {
        let duration = engine.currentDuration
        guard duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(engine.currentElapsed / duration)))
    }

    /// Remaining time of the current track as "-M:SS", or nil if unknown.
    private var remainingText: String? {
        let duration = engine.currentDuration
        guard duration > 0 else { return nil }
        let remaining = max(0, Int(duration - engine.currentElapsed))
        return String(format: "-%d:%02d", remaining / 60, remaining % 60)
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
