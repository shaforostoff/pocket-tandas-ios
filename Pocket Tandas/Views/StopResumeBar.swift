// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StopResumeBar.swift
//  Pocket Tandas
//
//  The middle control between browser and queue. Shows Stop while playing; turns
//  into Resume while a fade-out is in progress (pressing Resume cancels the
//  scheduled stop and continues playback). In Explore mode the same row also
//  carries Clear and Save for the play queue.
//

import SwiftUI

struct StopResumeBar: View {
    let mode: AppMode
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        HStack(spacing: 10) {
            if mode == .explore {
                SavePlaylistButton()
                ClearQueueButton()
            }
            if mode == .dj {
                EQButton()
            }
            stopOrResume
        }
        .controlSize(.large)
        .padding(.vertical, 8)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var stopOrResume: some View {
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
                // DJ mode fades out (configurable length); Explore stops at once.
                if mode == .dj {
                    engine.stopWithFade()
                } else {
                    engine.stop()
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!engine.state.isPlaying)
        }
    }
}
