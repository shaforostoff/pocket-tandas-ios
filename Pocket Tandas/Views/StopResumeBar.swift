// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StopResumeBar.swift
//  Pocket Tandas
//
//  The middle control between browser and queue.
//
//  DJ mode: Stop (a configurable fade-out) while playing, turning into Resume
//  while the fade is in progress (Resume cancels the scheduled stop). The row
//  also carries the EQ button.
//
//  Explore mode: Pause / Play instead — Pause holds the current track and Play
//  resumes it from where it left off. (To start a different track, or restart
//  the paused one, tap it in the queue while paused.) The row also carries Clear
//  and Save for the play queue.
//

import SwiftUI

struct StopResumeBar: View {
    let mode: AppMode
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            if mode == .explore {
                SavePlaylistButton()
                ClearQueueButton()
            }
            if mode == .dj {
                EQButton()
            }
            playbackControl
        }
        .controlSize(.large)
        // Keep each label on one line: "Pause" is wider than the old "Stop" and
        // overflowed the equal-thirds Explore row. Trim the margins for room and
        // allow a slight shrink as a last resort so nothing wraps/truncates.
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var playbackControl: some View {
        switch mode {
        case .dj:      djControl
        case .explore: exploreControl
        }
    }

    /// DJ: Stop (fade-out) ⇄ Resume (cancel the in-progress fade).
    @ViewBuilder
    private var djControl: some View {
        if engine.state.isFadingOut {
            Button {
                engine.resumeFromFade()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else {
            Button(role: .destructive) {
                engine.stopWithFade()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!engine.state.isPlaying)
        }
    }

    /// Explore: Pause ⇄ Play (continue from the paused position).
    @ViewBuilder
    private var exploreControl: some View {
        if engine.state.isPaused {
            Button {
                engine.resume()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else {
            Button {
                engine.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!engine.state.isPlaying)
        }
    }
}
