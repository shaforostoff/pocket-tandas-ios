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
//  also shows a live countdown ("-0:50") and pairs with QueueRowBackground to
//  draw a progress-bar-like fill behind the row.
//
//  Playback position isn't an observable property, so the current row ticks via
//  a TimelineView (~4 Hz) to refresh the countdown and the progress fill.
//

import SwiftUI

struct QueueRowView: View {
    let item: QueueItem
    var metadata: TrackMetadataSnapshot?
    let isCurrent: Bool
    let isFading: Bool
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            if isCurrent {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    TrackDisplayRow(display: display, titleAccessory: remainingText)
                }
            } else {
                TrackDisplayRow(display: display)
            }

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

    /// Remaining time of the current track as "-M:SS", or nil if unknown.
    private var remainingText: String? {
        let duration = engine.currentDuration
        guard duration > 0 else { return nil }
        let remaining = max(0, Int(duration - engine.currentElapsed))
        return String(format: "-%d:%02d", remaining / 60, remaining % 60)
    }
}

/// Row background for the queue: a progress-bar-like fill for the current track,
/// transparent otherwise. Used via `.listRowBackground`.
struct QueueRowBackground: View {
    let isCurrent: Bool

    var body: some View {
        if isCurrent {
            PlayingProgressBackground()
        } else {
            Color.clear
        }
    }
}

private struct PlayingProgressBackground: View {
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.accentColor.opacity(0.10)                 // unplayed track
                    Color.accentColor.opacity(0.28)                 // played portion
                        .frame(width: geo.size.width * fraction)
                }
            }
        }
    }

    private var fraction: CGFloat {
        let duration = engine.currentDuration
        guard duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(engine.currentElapsed / duration)))
    }
}
