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
//  scheduled stop and continues playback).
//

import SwiftUI

struct StopResumeBar: View {
    @Environment(PlaybackEngine.self) private var engine

    var body: some View {
        Group {
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
        .controlSize(.large)
        .padding(.vertical, 8)
        .padding(.horizontal)
    }
}
