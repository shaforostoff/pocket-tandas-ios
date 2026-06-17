// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MainScreenView.swift
//  Pocket Tandas
//
//  The shared main screen: file browser (top), Stop/Resume control (middle),
//  play queue (bottom). Carries the AppMode flag for future per-mode behaviour.
//

import SwiftUI
import SwiftData

struct MainScreenView: View {
    let mode: AppMode

    @Environment(PreListenPlayer.self) private var preListen

    /// Where the browser currently is, shared so the control bar's Save action
    /// can offer this folder and its parents. Lives here so it survives the
    /// browser/queue subviews and resets on each presentation of this screen.
    @State private var browser = BrowserState()

    var body: some View {
        VStack(spacing: 0) {
            BrowserView(mode: mode)
                .frame(maxHeight: .infinity)
            Divider()
            StopResumeBar(mode: mode)
            Divider()
            QueueView()
                .frame(maxHeight: .infinity)
        }
        .environment(browser)
        // Leaving the screen ends any prelistening — it's a foreground audition,
        // not background playback like the DJ queue.
        .onDisappear { preListen.stop() }
    }
}

#Preview {
    let session = AudioSessionController()
    let queue = PlayQueue()
    let container = try! ModelContainer(for: TrackMetadata.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let metadata = MetadataService(container: container)
    let equalizer = Equalizer()
    let routing = AudioRouting()
    return MainScreenView(mode: .dj)
        .environment(session)
        .environment(PlaybackEngine(audioSession: session, queue: queue, metadata: metadata, equalizer: equalizer, routing: routing))
        .environment(queue)
        .environment(LibraryStore())
        .environment(metadata)
        .environment(equalizer)
        .environment(routing)
        .environment(PreListenPlayer(audioSession: session, routing: routing))
        .modelContainer(container)
}

