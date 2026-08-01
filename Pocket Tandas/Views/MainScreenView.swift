// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MainScreenView.swift
//  Pocket Tandas
//
//  The shared main screen: file browser (top), Stop/Resume control (middle),
//  play queue (bottom). In the remote modes the link's own UI — status,
//  Disconnect, the peer picker — sits between that control row and the queue,
//  next to the list it governs. The AppMode flag selects behaviour:
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
    @Environment(Equalizer.self) private var equalizer
    @Environment(AudioSessionController.self) private var audioSession
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

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

    /// The two opt-in anti-suspension measures (launcher toggles, both time-limited
    /// — see StayAwake.swift) and the timer that releases them.
    @State private var keepAlive: SilentKeepAlive?
    @State private var stayAwakeTimer: Timer?

    init(mode: AppMode) {
        self.mode = mode
        if mode == .remoteSend {
            _remoteQueue = State(initialValue: RemoteQueue(link: PeerLink(role: .sender)))
        }
    }

    var body: some View {
        GeometryReader { proxy in
            // On a wide canvas (iPad — or a large iPhone — held landscape) split
            // left/right: browser on the left, queue + its controls on the right.
            // A compact width (iPhone) or portrait stays stacked top-to-bottom.
            let sideBySide = horizontalSizeClass == .regular && proxy.size.width > proxy.size.height
            VStack(spacing: 0) {
                if sideBySide {
                    sideBySideContent
                } else {
                    stackedContent
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Measure the full window, not the keyboard-shrunk area: otherwise the
        // filter keyboard can shrink the height enough to read as "landscape" and
        // flip the layout mid-typing (notably large iPads in portrait).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .environment(browser)
        .onAppear {
            startRemoteIfNeeded()
            beginStayAwakeWindow()
        }
        // Each return to the app restarts the window — the DJ is clearly present.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { beginStayAwakeWindow() }
        }
        // The silent keep-alive is only needed while the local engine is idle: real
        // playback keeps the app alive on its own.
        .onChange(of: engine.state) { _, _ in syncKeepAlive() }
        // Leaving the screen ends prelistening (a foreground audition) and tears
        // down any radios so they don't keep running back on the launcher.
        .onDisappear {
            preListen.stop()
            receiver?.stop()
            remoteQueue?.link.stop()
            endStayAwake()
        }
    }

    /// Portrait / compact: browser on top, Stop/Resume control, the remote banners,
    /// queue below — each list taking half the height.
    @ViewBuilder
    private var stackedContent: some View {
        topBrowser
            .frame(maxHeight: .infinity)
        Divider()
        StopResumeBar(mode: mode, control: control, remoteAudio: remoteQueue?.audio)
        Divider()
        remoteBanners
        queueSection
            .frame(maxHeight: .infinity)
    }

    /// Landscape on a regular-width device: browser fills the left half, the
    /// Stop/Resume control, remote banners and queue share the right half.
    @ViewBuilder
    private var sideBySideContent: some View {
        HStack(spacing: 0) {
            topBrowser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(spacing: 0) {
                StopResumeBar(mode: mode, control: control, remoteAudio: remoteQueue?.audio)
                Divider()
                remoteBanners
                queueSection
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Everything about the link — status, Disconnect, the peer picker, and the
    /// sender's add-failure notice — sits directly above the queue it governs.
    /// Each piece carries its own separator, since the connection banner hides
    /// itself once the link has settled.
    @ViewBuilder
    private var remoteBanners: some View {
        if mode.isRemoteSend, let remoteQueue {
            RemoteConnectionView(link: remoteQueue.link, role: .sender)
            remoteNotice
        } else if mode.isRemoteReceive, let receiver {
            RemoteConnectionView(link: receiver.link, role: .receiver)
        }
    }

    /// The bottom list. In Remote Control mode the mirror is hidden whenever the
    /// link is down — a queue that can't be driven and can't be trusted to still
    /// match the receiver is worse than none.
    @ViewBuilder
    private var queueSection: some View {
        if mode.isRemoteSend, !isRemoteConnected {
            disconnectedPlaceholder
        } else {
            QueueView(presenter: presenter)
        }
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Not connected")
                .font(.headline)
            Text("The remote queue appears once a Remote Controllable phone is connected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var isRemoteConnected: Bool {
        guard let remoteQueue else { return false }
        if case .connected = remoteQueue.link.connectionState { return true }
        return false
    }

    /// Top half: the file browser or the Music-library browser, per the source the
    /// Browse dropdown selected.
    @ViewBuilder
    private var topBrowser: some View {
        switch browser.source {
        case .files:
            BrowserView(mode: mode, remoteQueue: remoteQueue)
        case .music:
            MusicBrowserView(mode: mode, remoteQueue: remoteQueue)
        }
    }

    /// Brief banner shown to the sending DJ when the receiver couldn't resolve some
    /// added tracks (Remote Send only). Carries its own separator, as above.
    @ViewBuilder
    private var remoteNotice: some View {
        if mode.isRemoteSend, let notice = remoteQueue?.addFailureNotice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.9))
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

    // MARK: - Staying awake (opt-in, time-limited)

    /// Apply whichever launcher toggles are on and arm the release timer. With
    /// neither, nothing happens: iOS suspends the app on auto-lock as usual and the
    /// peer link goes quiet until the phone is unlocked (PeerLink rebuilds itself
    /// then — see its suspension-recovery note).
    private func beginStayAwakeWindow() {
        stayAwakeTimer?.invalidate()
        let wantsScreenAwake = StayAwakeSettings.screenStaysAwake
        let wantsKeepAlive = mode.isRemote && StayAwakeSettings.silentKeepAlive
        guard wantsScreenAwake || wantsKeepAlive else {
            endStayAwake()
            return
        }
        setIdleTimerDisabled(wantsScreenAwake)
        // Arm the deadline before starting the keep-alive: syncKeepAlive() treats a
        // nil timer as "outside the window".
        stayAwakeTimer = Timer.scheduledTimer(withTimeInterval: StayAwakeSettings.window,
                                              repeats: false) { _ in
            endStayAwake()
        }
        syncKeepAlive()
    }

    /// Release both measures — on the 30-minute deadline, or on leaving the screen.
    private func endStayAwake() {
        stayAwakeTimer?.invalidate()
        stayAwakeTimer = nil
        setIdleTimerDisabled(false)
        keepAlive?.stop()
    }

    /// Run the silent keep-alive only while it is wanted, still inside the window,
    /// and the local engine is idle (playing audio already prevents suspension).
    private func syncKeepAlive() {
        let wanted = mode.isRemote
            && StayAwakeSettings.silentKeepAlive
            && stayAwakeTimer != nil
            && engine.state == .idle
        guard wanted else {
            keepAlive?.stop()
            return
        }
        if keepAlive == nil { keepAlive = SilentKeepAlive(audioSession: audioSession) }
        keepAlive?.start()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    private func startRemoteIfNeeded() {
        guard !startedRemote else { return }
        startedRemote = true
        switch mode {
        case .remoteReceive:
            let coordinator = RemoteReceiverCoordinator(queue: queue, engine: engine, metadata: metadata,
                                                        library: library, equalizer: equalizer,
                                                        container: modelContext.container)
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
