// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MainScreenView.swift
//  Pocket Tandas
//
//  The shared main screen: file browser (top), Stop/Resume control (middle),
//  play queue (bottom). The AppMode flag selects behaviour:
//   - Explore / DJ: drive the local engine and local PlayQueue.
//   - Remote Receive (extends DJ): also broadcast queue/playback to a sender and
//     apply its commands, via a screen-scoped RemoteReceiverCoordinator.
//   - Remote Send (extends Explore): hide the local queue, show a mirror of the
//     receiver's queue (RemoteQueue), and route transport + swipe-to-add over the
//     peer link. Local prelistening stays available for headphone monitoring.
//
//  The remote radios are screen-scoped (created here, torn down on disappear) so
//  they only run while a remote screen is open.
//

import SwiftUI
import SwiftData

struct MainScreenView: View {
    let mode: AppMode

    @Environment(PreListenPlayer.self) private var preListen
    @Environment(PlayQueue.self) private var queue
    @Environment(PlaybackEngine.self) private var engine
    @Environment(MetadataService.self) private var metadata
    @Environment(LibraryStore.self) private var library
    @Environment(\.modelContext) private var modelContext

    /// Where the browser currently is, shared so the control bar's Save action
    /// can offer this folder and its parents. Resets on each presentation.
    @State private var browser = BrowserState()

    /// Live only in Remote Send: the mirror of the receiver's queue plus the peer
    /// link. Created eagerly (below) so the local queue never flashes before the
    /// mirror is wired.
    @State private var remoteQueue: RemoteQueue?
    /// Live only in Remote Receive: broadcasts local state and applies commands.
    @State private var receiver: RemoteReceiverCoordinator?
    @State private var startedRemote = false

    init(mode: AppMode) {
        self.mode = mode
        if mode == .remoteSend {
            _remoteQueue = State(initialValue: RemoteQueue(link: PeerLink(role: .sender)))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBanner
            BrowserView(mode: mode, remoteQueue: remoteQueue)
                .frame(maxHeight: .infinity)
            Divider()
            StopResumeBar(mode: mode, control: control)
            Divider()
            QueueView(presenter: presenter)
                .frame(maxHeight: .infinity)
        }
        .environment(browser)
        .onAppear { startRemoteIfNeeded() }
        // Leaving the screen ends prelistening (a foreground audition) and tears
        // down any radios so they don't keep running back on the launcher.
        .onDisappear {
            preListen.stop()
            receiver?.stop()
            remoteQueue?.link.stop()
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if mode.isRemoteSend, let remoteQueue {
            RemoteConnectionView(link: remoteQueue.link, role: .sender)
            Divider()
        } else if mode.isRemoteReceive, let receiver {
            RemoteConnectionView(link: receiver.link, role: .receiver)
            Divider()
        }
    }

    /// The transport the Stop/Resume bar drives: the remote mirror in Remote Send,
    /// otherwise the local engine.
    private var control: any PlaybackControlling {
        if mode.isRemoteSend, let remoteQueue { return remoteQueue }
        return engine
    }

    /// The queue the bottom list renders: the remote mirror in Remote Send,
    /// otherwise the local play queue.
    private var presenter: any QueuePresenting {
        if mode.isRemoteSend, let remoteQueue {
            return RemoteQueuePresenter(remote: remoteQueue)
        }
        return LocalQueuePresenter(queue: queue, engine: engine, metadata: metadata)
    }

    private func startRemoteIfNeeded() {
        guard !startedRemote else { return }
        startedRemote = true
        switch mode {
        case .remoteReceive:
            let coordinator = RemoteReceiverCoordinator(queue: queue, engine: engine, metadata: metadata,
                                                        library: library, container: modelContext.container)
            coordinator.start()
            receiver = coordinator
        case .remoteSend:
            remoteQueue?.link.startBrowsing()
        default:
            break
        }
    }
}

#Preview {
    let session = AudioSessionController()
    let queue = PlayQueue()
    let container = try! ModelContainer(for: TrackMetadata.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let metadata = MetadataService(container: container)
    let equalizer = Equalizer()
    return MainScreenView(mode: .dj)
        .environment(session)
        .environment(PlaybackEngine(audioSession: session, queue: queue, metadata: metadata, equalizer: equalizer))
        .environment(queue)
        .environment(LibraryStore())
        .environment(metadata)
        .environment(equalizer)
        .environment(PreListenPlayer(audioSession: session))
        .modelContainer(container)
}
