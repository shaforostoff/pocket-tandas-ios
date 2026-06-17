// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteQueue.swift
//  Pocket Tandas
//
//  Sender-side mirror of the receiver's play queue and playback state, used in
//  Remote Send mode. It is authoritative-read-only: it is only ever mutated by
//  snapshots/progress received from the receiver (never optimistically), so it
//  can't drift. Its intent methods send commands; the resulting change comes back
//  as the next snapshot.
//

import Foundation
import Observation

@Observable
final class RemoteQueue {
    private(set) var items: [RemoteQueueItem] = []
    private(set) var playback = RemotePlaybackState()
    private(set) var progress = RemoteProgress()

    @ObservationIgnored let link: PeerLink
    @ObservationIgnored private var lastSnapshotSeq: UInt64 = 0
    @ObservationIgnored private var lastProgressSeq: UInt64 = 0

    init(link: PeerLink) {
        self.link = link
        link.onReceive = { [weak self] message in self?.handle(message) }
        link.onConnected = { [weak self] _ in
            // Fresh receiver session may restart its seq counter — reset ours so
            // the first new snapshot isn't rejected, then ask for current state.
            self?.lastSnapshotSeq = 0
            self?.lastProgressSeq = 0
            self?.link.send(.requestSnapshot)
        }
    }

    // MARK: - Read-throughs for the UI

    var anchorID: UUID? { items.first(where: { $0.isAnchor })?.id }
    var currentItemID: UUID? { playback.currentItemID }

    // MARK: - Inbound state

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .snapshot(let snapshot):
            guard snapshot.seq > lastSnapshotSeq else { return }
            lastSnapshotSeq = snapshot.seq
            items = snapshot.items
            playback = snapshot.playback
        case .progress(let progress):
            guard progress.seq > lastProgressSeq else { return }
            lastProgressSeq = progress.seq
            self.progress = progress
        case .addTrackResult, .requestPlay, .stopWithFade, .resumeFromFade,
             .setAnchor, .move, .removeItems, .addTracks, .requestSnapshot:
            break   // not consumed by the sender
        }
    }

    // MARK: - Outbound intents (commands)

    func requestPlay(id: UUID) { link.send(.requestPlay(itemID: id)) }
    func setAnchor(id: UUID?) { link.send(.setAnchor(itemID: id)) }
    func move(ids: [UUID], toOffset: Int) { link.send(.move(itemIDs: ids, toOffset: toOffset)) }
    func removeItems(ids: [UUID]) { link.send(.removeItems(itemIDs: ids)) }
    func addTracks(_ requests: [TrackAddRequest]) {
        guard !requests.isEmpty else { return }
        link.send(.addTracks(requests))
    }
}

// MARK: - PlaybackControlling (drives StopResumeBar in Remote Send mode)

extension RemoteQueue: PlaybackControlling {
    var isPlaying: Bool { playback.isPlaying }
    var isFadingOut: Bool { playback.isFadingOut }
    var isPaused: Bool { playback.isPaused }
    func stopWithFade() { link.send(.stopWithFade) }
    func resumeFromFade() { link.send(.resumeFromFade) }
    func pause() {}    // unused: Remote Send uses the DJ-style Stop/Resume control
    func resume() {}
}
