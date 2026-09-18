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
//  plus a lightweight progress tick on a timer. The audio chain (EQ bands, master
//  volume, and the two disc restoration filters) is tracked and broadcast
//  separately, and the sender's EQ / volume / restoration commands are applied to
//  the same Equalizer / PlaybackEngine / RestorationFilters the local panels
//  drive — so both ends stay in step. Plain @Observable (used as @State in
//  MainScreenView), not @MainActor — see observable-not-mainactor.
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
    @ObservationIgnored private let equalizer: Equalizer
    @ObservationIgnored private let restoration: RestorationFilters
    @ObservationIgnored private let container: ModelContainer

    @ObservationIgnored private var seq: UInt64 = 0
    @ObservationIgnored private var broadcastScheduled = false
    @ObservationIgnored private var playbackBroadcastScheduled = false
    @ObservationIgnored private var settingsBroadcastScheduled = false
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var running = false

    /// Display text already sent to the CURRENT sender, per row — the basis for
    /// omitting it from later snapshots. Cleared whenever a sender (re)connects or
    /// asks for a full resync, so it can never claim the peer knows something it
    /// doesn't, and pruned to the live queue so it can't grow unbounded.
    @ObservationIgnored private var sentText: [UUID: RowText] = [:]
    /// The compact identity handed to the sender for each queue item, and the way
    /// back. Both are rebuilt from the live queue on every snapshot, so a handle
    /// outlives its row only for as long as a command already in flight might name
    /// it — and one that names a row we no longer have is meant to be ignored.
    @ObservationIgnored private var handleByItem: [UUID: RowHandle] = [:]
    @ObservationIgnored private var itemByHandle: [RowHandle: UUID] = [:]
    @ObservationIgnored private var nextHandle: RowHandle = 1
    /// What the sender already has, so an unchanged rebuild (queue untouched, e.g.
    /// metadata churn from browsing on this device) isn't resent. Only the row
    /// identities/anchors and playback are compared — the text is covered by
    /// `sentText`, and the same state can serialize as full rows once and text-less
    /// rows thereafter.
    @ObservationIgnored private var lastSent: SentState?
    /// The seq of what the sender is holding, so a delta can name the base it edits.
    /// Zero means we can't know — send the whole queue.
    @ObservationIgnored private var lastSentSeq: UInt64 = 0

    private struct RowText: Equatable {
        let title: String
        let artist: String?
        let detail: String?
    }

    private struct SentState: Equatable {
        let rows: [RowHandle]
        let anchor: RowHandle?
        let playback: RemotePlaybackState
    }

    init(queue: PlayQueue, engine: PlaybackEngine, metadata: MetadataService,
         library: LibraryStore, equalizer: Equalizer, restoration: RestorationFilters,
         container: ModelContainer) {
        self.queue = queue
        self.engine = engine
        self.metadata = metadata
        self.library = library
        self.equalizer = equalizer
        self.restoration = restoration
        self.container = container
        self.link = PeerLink(role: .receiver)
        link.onReceive = { [weak self] message in self?.handle(message) }
        link.onConnected = { [weak self] _ in
            // A new sender knows nothing: start describing every row in full again.
            self?.forgetSentText()
            self?.broadcastSnapshot()
            self?.broadcastAudioSettings()
            self?.broadcastProgress(force: true)   // don't make a fresh sender wait out the interval
        }
    }

    func start() {
        guard !running else { return }
        running = true
        // Request Music access once so a sender's media tracks can resolve against
        // this receiver's (synced) library. No-op if already authorized/denied.
        #if os(iOS)
        Task { _ = await MediaLibraryImporter.requestAuthorization() }
        #endif
        link.startAdvertising()
        observe()
        observePlayback()
        observeAudioSettings()
        startProgressTimer()
    }

    func stop() {
        running = false
        progressTimer?.invalidate()
        progressTimer = nil
        link.stop()
    }

    // MARK: - Observe → broadcast

    /// Structural/display state → full snapshot. Playback is tracked separately
    /// (below) so a track transition doesn't drag the whole queue onto the wire.
    private func observe() {
        withObservationTracking {
            _ = queue.items
            _ = queue.anchorID
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

    private func observePlayback() {
        withObservationTracking {
            _ = engine.state
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.schedulePlaybackBroadcast()
                self.observePlayback()
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

    private func schedulePlaybackBroadcast() {
        guard !playbackBroadcastScheduled else { return }
        playbackBroadcastScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.playbackBroadcastScheduled = false
            self.link.send(.playbackState(RemotePlaybackUpdate(playback: self.makePlayback(),
                                                               seq: self.nextSeq())))
            // The transition itself carries the final position: a deck that has just
            // stopped ticking would otherwise freeze the sender's countdown wherever
            // the last tick left it, up to a second short.
            self.broadcastProgress(force: true)
        }
    }

    /// EQ + volume are tracked separately from the queue so a slider drag on the
    /// sender doesn't echo the whole queue back on every tick.
    private func observeAudioSettings() {
        withObservationTracking {
            _ = equalizer.isEnabled
            _ = equalizer.bands
            _ = engine.masterVolume
            _ = restoration.declickEnabled
            _ = restoration.dehumEnabled
            _ = restoration.declick
            _ = restoration.dehum
            // Read-only, but they are what the sender's Detected list shows, and
            // this is the only message they can travel in. Neither churns: the
            // detector is polled slowly and republishes only when a line has
            // actually moved. See RestorationFilters.detectedLines.
            _ = restoration.detectedLines
            _ = restoration.scoutState
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.scheduleSettingsBroadcast()
                self.observeAudioSettings()
            }
        }
    }

    private func scheduleSettingsBroadcast() {
        guard !settingsBroadcastScheduled else { return }
        settingsBroadcastScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsBroadcastScheduled = false
            self.broadcastAudioSettings()
        }
    }

    /// Build the snapshot and send it — unless it is byte-for-byte what the sender
    /// already has. The text cache is committed only on an actual send, so a
    /// skipped snapshot can't leave us believing the peer saw text it never got.
    private func broadcastSnapshot() {
        let (items, text) = makeItems()
        let playback = makePlayback()
        let anchor = queue.anchorID.flatMap { handleByItem[$0] }
        let state = SentState(rows: items.map(\.id), anchor: anchor, playback: playback)
        // Nothing to say: same rows in the same order, no row's text has changed.
        if lastSent == state, !items.contains(where: \.hasText) { return }
        let seq = nextSeq()
        let message = framing(items: items, anchor: anchor, playback: playback, seq: seq)
        sentText = text
        lastSent = state
        lastSentSeq = seq
        link.send(message)
    }

    /// An edit script when it is genuinely smaller, the whole queue otherwise.
    ///
    /// Both are built and encoded so the choice is made on real bytes rather than a
    /// guess: the greedy script anchors on the first row that lines up, so a queue
    /// rotated or rebuilt wholesale can produce a "delta" longer than the snapshot
    /// it would replace. Encoding twice costs a compression pass on a message that
    /// is only sent when something actually changed.
    private func framing(items: [RemoteQueueItem], anchor: RowHandle?,
                         playback: RemotePlaybackState, seq: UInt64) -> RemoteMessage {
        let snapshot = RemoteMessage.snapshot(RemoteSnapshot(items: items, anchor: anchor,
                                                             playback: playback, seq: seq))
        guard let base = lastSent, lastSentSeq != 0 else { return snapshot }
        let script = QueueEditScript.make(from: base.rows, to: items)
        let delta = RemoteMessage.delta(RemoteQueueDelta(baseSeq: lastSentSeq, seq: seq,
                                                         removed: script.removed,
                                                         inserted: script.inserted,
                                                         anchor: anchor, playback: playback,
                                                         count: items.count))
        guard let deltaSize = delta.encoded()?.count,
              let snapshotSize = snapshot.encoded()?.count,
              deltaSize < snapshotSize else { return snapshot }
        return delta
    }

    /// Drop what we believe the sender knows, so the next snapshot re-describes
    /// every row in full (on (re)connect, or an explicit resync request).
    private func forgetSentText() {
        sentText = [:]
        lastSent = nil
        lastSentSeq = 0
    }

    private func broadcastAudioSettings() {
        link.send(.audioSettings(RemoteAudioSettings(eqEnabled: equalizer.isEnabled,
                                                     bands: equalizer.bands,
                                                     volume: engine.masterVolume,
                                                     declickEnabled: restoration.declickEnabled,
                                                     dehumEnabled: restoration.dehumEnabled,
                                                     declick: restoration.declick,
                                                     dehum: restoration.dehum,
                                                     dehumLines: restoration.detectedLines,
                                                     scoutPhase: restoration.scoutPhase,
                                                     declickLatency: restoration.declickLatency,
                                                     seq: nextSeq())))
    }

    /// The rows to send, plus the text cache that would result from sending them.
    /// A row carries its text only when the sender hasn't been told it yet or it has
    /// changed since — a newly queued track, or one whose metadata scan has just
    /// replaced a filename with a real title.
    private func makeItems() -> (items: [RemoteQueueItem], text: [UUID: RowText]) {
        var text: [UUID: RowText] = [:]
        text.reserveCapacity(queue.items.count)
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
            let row = RowText(title: display.titleLine, artist: display.artistLine,
                              detail: display.detailLine)
            // Pruning falls out of rebuilding the map from the live queue.
            text[item.id] = row
            let handle = wireHandle(for: item.id)
            guard sentText[item.id] != row else {
                return RemoteQueueItem(id: handle, title: nil, artist: nil, detail: nil)
            }
            return RemoteQueueItem(id: handle, title: row.title, artist: row.artist,
                                   detail: row.detail)
        }
        pruneHandles()
        return (items, text)
    }

    /// The sender-facing identity of a queue item, minted on first sight.
    private func wireHandle(for id: UUID) -> RowHandle {
        if let existing = handleByItem[id] { return existing }
        let handle = nextHandle
        nextHandle += 1
        handleByItem[id] = handle
        itemByHandle[handle] = id
        return handle
    }

    /// Keep the tables to the live queue so a long set can't grow them without
    /// bound. Handles are never reused, so a dropped one can only ever be a command
    /// aimed at a row that has already gone.
    private func pruneHandles() {
        let live = Set(queue.items.map(\.id))
        handleByItem = handleByItem.filter { live.contains($0.key) }
        itemByHandle = itemByHandle.filter { live.contains($0.value) }
    }

    private func makePlayback() -> RemotePlaybackState {
        let kind: RemotePlaybackState.Kind
        switch engine.state {
        case .idle: kind = .idle
        case .playing: kind = .playing
        case .fadingOut: kind = .fadingOut
        case .paused: kind = .paused
        }
        return RemotePlaybackState(kind: kind,
                                   currentItemID: engine.state.currentItemID.map { wireHandle(for: $0) },
                                   duration: engine.currentDuration)
    }

    /// Once every ten seconds, not once a second: the sender advances the countdown
    /// on its own clock and only needs the truth often enough to correct drift, which
    /// between two phones over ten seconds is a few tens of milliseconds. Transitions
    /// send their own position, so this is purely the correction.
    @ObservationIgnored private static let progressInterval: TimeInterval = 10

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: Self.progressInterval, repeats: true) { [weak self] _ in
            self?.broadcastProgress()
        }
    }

    /// Audio is actually moving. Note that a fade-out still is — the countdown keeps
    /// running through it — where a pause is not.
    private var isAdvancing: Bool {
        engine.state.isPlaying || engine.state.isFadingOut
    }

    /// Ticks only while the position is changing. A paused deck holds a currentItemID
    /// for as long as it stays loaded, so the old guard let it retransmit the same
    /// elapsed once a second for as long as the DJ left it paused. `force` is for the
    /// transitions themselves, which do need to carry a position.
    private func broadcastProgress(force: Bool = false) {
        guard force || isAdvancing else { return }
        guard engine.state.currentItemID != nil else { return }
        // Two decimals: past what a per-second countdown can show, and short enough
        // that the number doesn't cost more than the rest of the message.
        let elapsed = (engine.currentElapsed * 100).rounded() / 100
        link.send(.progress(RemoteProgress(elapsed: elapsed, seq: nextSeq())))
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    // MARK: - Apply incoming commands (the same methods the local UI calls)

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .requestPlay(let handle):
            if let id = itemByHandle[handle], let item = queue.item(withID: id) { engine.requestPlay(item) }
        case .stopWithFade:
            engine.stopWithFade()
        case .resumeFromFade:
            engine.resumeFromFade()
        case .setAnchor(let handle):
            // An unknown handle is a stale row, not a request to clear the anchor —
            // only an explicit nil clears it.
            if let handle {
                if let id = itemByHandle[handle] { queue.setAnchor(id) }
            } else {
                queue.setAnchor(nil)
            }
        case .move(let handles, let toOffset):
            applyMove(ids: handles.compactMap { itemByHandle[$0] }, toOffset: toOffset)
        case .removeItems(let handles):
            applyRemove(ids: handles.compactMap { itemByHandle[$0] })
        case .addTracks(let requests):
            Task { @MainActor in self.applyAddTracks(requests) }
        case .requestSnapshot:
            // A resync request means the sender can't resolve what it has — describe
            // every row in full again.
            forgetSentText()
            broadcastSnapshot()
            broadcastProgress(force: true)
        case .setEQEnabled(let on):
            equalizer.setEnabled(on)
        case .setEQBand(let id, let gain, let frequency, let bandwidth):
            equalizer.setGain(gain, bandID: id)
            equalizer.setFrequency(frequency, bandID: id)
            equalizer.setBandwidth(bandwidth, bandID: id)
        case .setEQBandEnabled(let id, let on):
            equalizer.setBandEnabled(on, bandID: id)
        case .setEQPreset(let preset):
            equalizer.apply(preset)
        case .resetEQ:
            equalizer.reset()
        case .setVolume(let level):
            engine.setMasterVolume(level)
        case .setDeclickEnabled(let on):
            restoration.setDeclickEnabled(on)
        case .setDehumEnabled(let on):
            restoration.setDehumEnabled(on)
        case .setDeclick(let settings):
            restoration.updateDeclick { $0 = settings }
        case .setDehum(let settings):
            restoration.updateDehum { $0 = settings }
        case .resetDeclick:
            restoration.resetDeclick()
        case .resetDehum:
            restoration.resetDehum()
        case .requestAudioSettings:
            broadcastAudioSettings()
        case .snapshot, .delta, .playbackState, .progress, .addTrackResult, .audioSettings:
            break   // receiver→sender messages; ignored here
        case .goodbye:
            break   // handled in PeerLink
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
            #if os(iOS)
            case .media(let mediaItem):
                guard let assetURL = mediaItem.assetURL else { continue }
                let ref = MediaRef(persistentID: mediaItem.persistentID, assetURL: assetURL,
                                   displayTitle: mediaItem.title ?? "Unknown", duration: mediaItem.playbackDuration)
                let snapshot = TrackMetadataSnapshot(mediaItem: mediaItem)
                items.append(QueueItem(media: ref, snapshot: snapshot))
            #endif
            case nil:
                continue
            }
        }
        if !items.isEmpty {
            queue.enqueue(contentsOf: items)
            if !fileURLs.isEmpty { metadata.scan(urls: fileURLs, baseURL: library.baseURL) }   // files only
            metadata.seedMedia(items)                                                          // media only
        }
        link.send(.addTrackResult(resolved: items.count, failed: requests.count - items.count))
    }
}
