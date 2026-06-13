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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrowserView()
                    .frame(maxHeight: .infinity)
                Divider()
                StopResumeBar()
                Divider()
                QueueView()
                    .frame(maxHeight: .infinity)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Launcher", systemImage: "chevron.left")
                    }
                }
            }
        }
    }

}

#Preview {
    let session = AudioSessionController()
    let queue = PlayQueue()
    let container = try! ModelContainer(for: TrackMetadata.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return MainScreenView(mode: .dj)
        .environment(session)
        .environment(PlaybackEngine(audioSession: session, queue: queue))
        .environment(queue)
        .environment(LibraryStore())
        .environment(MetadataService(container: container))
        .modelContainer(container)
}

