// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  Pocket_TandasApp.swift
//  Pocket Tandas
//

import SwiftUI
import SwiftData

@main
struct Pocket_TandasApp: App {
    /// App-scoped, long-lived objects injected via the environment so they
    /// outlive any screen (playback must survive navigating back to the launcher).
    @State private var audioSession: AudioSessionController
    @State private var playQueue: PlayQueue
    @State private var engine: PlaybackEngine
    @State private var library: LibraryStore
    @State private var metadata: MetadataService
    @State private var nowPlaying: NowPlayingController
    @State private var equalizer: Equalizer
    @State private var routing: AudioRouting
    @State private var preListen: PreListenPlayer

    /// Durable metadata cache. Runtime state lives in plain observable objects,
    /// not SwiftData: the play queue persists itself to a small JSON file (see
    /// PlayQueue), and playback state is ephemeral.
    private let modelContainer: ModelContainer

    init() {
        let container = Self.makeModelContainer()
        let session = AudioSessionController()
        // library before queue: restoring the queue resolves entries against the
        // base folder, which the library re-grants in its initializer.
        let library = LibraryStore()
        let queue = PlayQueue()
        queue.restore(baseURL: library.baseURL)
        // metadata before engine: the engine reads each track's ReplayGain from it.
        let metadata = MetadataService(container: container)
        let equalizer = Equalizer()
        let routing = AudioRouting()
        let engine = PlaybackEngine(audioSession: session, queue: queue, metadata: metadata, equalizer: equalizer, routing: routing)
        let nowPlaying = NowPlayingController(engine: engine, metadata: metadata)
        // The cue shares the audio session. In single-route mode (.off / Explore)
        // starting queue playback tears the cue down so the two never overlap; in a
        // cue routing they play on separate outputs and stay fully independent.
        let preListen = PreListenPlayer(audioSession: session, routing: routing)
        engine.onPlaybackStart = { [weak preListen, weak routing] in
            if routing?.mode == .off { preListen?.stop() }
        }

        self.modelContainer = container
        _audioSession = State(initialValue: session)
        _library = State(initialValue: library)
        _playQueue = State(initialValue: queue)
        _engine = State(initialValue: engine)
        _metadata = State(initialValue: metadata)
        _nowPlaying = State(initialValue: nowPlaying)
        _equalizer = State(initialValue: equalizer)
        _routing = State(initialValue: routing)
        _preListen = State(initialValue: preListen)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([TrackMetadata.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            LauncherView()
                .environment(audioSession)
                .environment(engine)
                .environment(library)
                .environment(playQueue)
                .environment(metadata)
                .environment(equalizer)
                .environment(routing)
                .environment(preListen)
                .task {
                    // Warm the cache for the restored queue so its rows show
                    // titles/artists at launch, not just filenames.
                    metadata.scan(urls: playQueue.items.map(\.url), baseURL: library.baseURL)
                }
                .onChange(of: library.baseURL) { _, newValue in
                    playQueue.baseURL = newValue
                }
        }
        .modelContainer(modelContainer)
    }
}
