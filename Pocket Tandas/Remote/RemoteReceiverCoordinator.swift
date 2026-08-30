// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteReceiverCoordinator.swift
//  Pocket Tandas
//
//  Drives Remote Receive mode (extends DJ): it exposes the local play queue and
//  playback state to a connected sender and applies the sender's commands by
//  calling the SAME PlayQueue / PlaybackEngine methods the local DJ UI uses — so
//  there is no separate playback path, and the receiver's own UI keeps working.
//
//  It watches queue.items / queue.anchorID / engine.state / metadata.snapshots
//  via observation tracking and broadcasts a coalesced snapshot on any change,
//  plus a lightweight progress tick on a timer. Plain @Observable (used as @State
//  in MainScreenView), not @MainActor — see observable-not-mainactor.
//

import Foundation
import SwiftData
import Observation
import MediaPlayer

@Observable
final class RemoteReceiverCoordinator {
    @ObservationIgnored let link: PeerLink

    @ObservationIgnored private let queue: PlayQueue
    @ObservationIgnored private let engine: PlaybackEngine
    @ObservationIgnored private let metadata: MetadataService
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let container: ModelContainer

    @ObservationIgnored private var seq: UInt64 = 0
    @ObservationIgnored private var broadcastScheduled = false
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var running = false

    init(queue: PlayQueue, engine: PlaybackEngine, metadata: MetadataService,
         library: LibraryStore, container: ModelContainer) {
        self.queue = queue
        self.engine = engine
        self.metadata = metadata
        self.library = library
        self.container = container
        self.link = PeerLink(role: .receiver)
        link.onReceive = { [weak self] message in self?.handle(message) }
        link.onConnected = { [weak self] _ in self?.broadcastSnapshot() }
    }

    func start() {
        guard !running else { return }
        running = true
        // Request Music access once so a sender's media tracks can resolve against
        // this receiver's (synced) library. No-op if already authorized/denied.
        Task { _ = await MediaLibraryImporter.requestAuthorization() }
        link.startAdvertising()
        observe()
        startProgressTimer()
    }

    func stop() {
        running = false
        progressTimer?.invalidate()
        progressTimer = nil
        link.stop()
    }

    // MARK: - Observe → broadcast

    private func observe() {
        withObservationTracking {
            _ = queue.items
            _ = queue.anchorID
            _ = engine.state
            _ = metadata.snapshots
        } onChange: { [weak self] in
            // onChange fires on willSet (old values still in place); hop to main to
            // read the new values, coalesce a broadcast, and re-arm tracking.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.scheduleBroadcast()
                self.observe()
            }
        }
    }

    /// Coalesce a burst of changes (e.g. a multi-track insert) into one snapshot
    /// per runloop turn.
    private func scheduleBroadcast() {
        guard !broadcastScheduled else { return }
        broadcastScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.broadcastScheduled = false
            self.broadcastSnapshot()
        }
    }

    private func broadcastSnapshot() {
        link.send(.snapshot(makeSnapshot()))
    }

    private func makeSnapshot() -> RemoteSnapshot {
        let anchorID = queue.anchorID
        let items = queue.items.map { item -> RemoteQueueItem in
            // Media items carry their own snapshot (seeded at enqueue); fall back to
            // it if the cache hasn't been populated.
            let snapshot = metadata.snapshot(forKey: item.trackKey) ?? item.mediaSnapshot
            let display: TrackDisplay
            if let snapshot, !snapshot.isEmpty {
                display = TrackDisplay(metadata: snapshot, fallback: item.filename)
            } else {
                display = TrackDisplay(filename: item.filename)
            }
            return RemoteQueueItem(id: item.id, title: display.titleLine, artist: display.artistLine,
                                   detail: display.detailLine, isAnchor: item.id == anchorID)
        }
        return RemoteSnapshot(items: items, playback: makePlayback(), seq: nextSeq())
    }

    private func makePlayback() -> RemotePlaybackState {
        let kind: RemotePlaybackState.Kind
        switch engine.state {
        case .idle: kind = .idle
        case .playing: kind = .playing
        case .fadingOut: kind = .fadingOut
        case .paused: kind = .paused
        }
        return RemotePlaybackState(kind: kind, currentItemID: engine.state.currentItemID)
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.broadcastProgress()
        }
    }

    private func broadcastProgress() {
        guard let currentID = engine.state.currentItemID else { return }
        let progress = RemoteProgress(itemID: currentID,
                                      elapsed: engine.currentElapsed,
                                      duration: engine.currentDuration,
                                      seq: nextSeq())
        link.send(.progress(progress))
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    // MARK: - Apply incoming commands (the same methods the local UI calls)

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .requestPlay(let id):
            if let item = queue.item(withID: id) { engine.requestPlay(item) }
        case .stopWithFade:
            engine.stopWithFade()
        case .resumeFromFade:
            engine.resumeFromFade()
        case .setAnchor(let id):
            queue.setAnchor(id)
        case .move(let ids, let toOffset):
            applyMove(ids: ids, toOffset: toOffset)
        case .removeItems(let ids):
            applyRemove(ids: ids)
        case .addTracks(let requests):
            Task { @MainActor in self.applyAddTracks(requests) }
        case .requestSnapshot:
            broadcastSnapshot()
        case .snapshot, .progress, .addTrackResult:
            break   // receiver→sender messages; ignored here
        }
    }

    private func applyMove(ids: [UUID], toOffset: Int) {
        let offsets = ids.compactMap { queue.index(of: $0) }
        guard !offsets.isEmpty else { return }
        // PlayQueue rejects relocating the currently playing track (by identity).
        queue.move(fromOffsets: IndexSet(offsets), toOffset: toOffset, pinnedID: engine.state.currentItemID)
    }

    private func applyRemove(ids: [UUID]) {
        let currentID = engine.state.currentItemID
        let offsets = ids.filter { $0 != currentID }.compactMap { queue.index(of: $0) }
        guard !offsets.isEmpty else { return }
        queue.remove(atOffsets: IndexSet(offsets))
    }

    /// Resolve each request to a local file and enqueue (honouring the anchor),
    /// then scan their metadata so the rows fill in. @MainActor for metadata.scan
    /// and queue mutation; reached via a hop from handle().
    @MainActor
    private func applyAddTracks(_ requests: [TrackAddRequest]) {
        let resolver = RemoteTrackResolver(baseURL: library.baseURL, container: container)
        var items: [QueueItem] = []
        var fileURLs: [URL] = []
        for request in requests {
            switch resolver.resolve(request) {
            case .file(let url):
                items.append(QueueItem(url: url, trackKey: StableTrackID.key(for: url, baseURL: library.baseURL)))
                fileURLs.append(url)
            case .media(let mediaItem):
                guard let assetURL = mediaItem.assetURL else { continue }
                let ref = MediaRef(persistentID: mediaItem.persistentID, assetURL: assetURL,
                                   displayTitle: mediaItem.title ?? "Unknown", duration: mediaItem.playbackDuration)
                let snapshot = TrackMetadataSnapshot(mediaItem: mediaItem)
                let queueItem = QueueItem(media: ref, snapshot: snapshot)
                metadata.inject(snapshot, forKey: queueItem.trackKey)
                items.append(queueItem)
            case nil:
                continue
            }
        }
        if !items.isEmpty {
            queue.enqueue(contentsOf: items)
            if !fileURLs.isEmpty { metadata.scan(urls: fileURLs, baseURL: library.baseURL) }   // files only
        }
        link.send(.addTrackResult(resolved: items.count, failed: requests.count - items.count))
    }
}
