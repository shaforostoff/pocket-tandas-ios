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
//  Rows whose display text the receiver has already sent on this connection arrive
//  text-less and are filled in from the mirror (see `merge`), so a queue's names
//  cross the wire once rather than on every change. Playback state arrives either
//  inside a snapshot or, when only the engine moved, as its own small message.
//

import Foundation
import Observation

/// One row of the mirror as the UI sees it.
///
/// The wire names rows by a compact RowHandle; the queue UI is the very same view
/// that renders the local queue and names rows by UUID. A locally-minted UUID per
/// handle, kept for as long as the row is known, bridges the two so neither side
/// has to learn about the other's scheme.
struct MirrorRow: Identifiable, Hashable {
    let id: UUID
    let handle: RowHandle
    let title: String?
    let artist: String?
    let detail: String?
    let isAnchor: Bool
}

@Observable
final class RemoteQueue {
    private(set) var items: [MirrorRow] = []
    private(set) var playback = RemotePlaybackState()

    /// The last position the receiver sent and the instant it landed — the base the
    /// countdown runs from between updates.
    @ObservationIgnored private var progressBase: (elapsed: TimeInterval, at: Date)?

    /// Brief notice for the Remote Send UI when the receiver couldn't resolve some
    /// added tracks (not in its library / not playable). Auto-clears after a moment.
    private(set) var addFailureNotice: String?

    @ObservationIgnored let link: PeerLink

    /// The receiver's audio chain (EQ + master volume), driven by the EQ and Volume
    /// buttons on the Remote Control screen. Shares this link.
    @ObservationIgnored let audio: RemoteAudioControl

    /// Handle ↔ local UUID, pruned to the live rows on each snapshot.
    @ObservationIgnored private var localIDs: [RowHandle: UUID] = [:]
    @ObservationIgnored private var handles: [UUID: RowHandle] = [:]

    @ObservationIgnored private var lastSnapshotSeq: UInt64 = 0
    @ObservationIgnored private var lastPlaybackSeq: UInt64 = 0
    @ObservationIgnored private var lastProgressSeq: UInt64 = 0

    init(link: PeerLink) {
        self.link = link
        self.audio = RemoteAudioControl(link: link)
        link.onReceive = { [weak self] message in self?.handle(message) }
        link.onConnected = { [weak self] _ in
            guard let self else { return }
            // Fresh receiver session may restart its seq counter — reset ours so
            // the first new snapshot isn't rejected, then ask for current state.
            self.lastSnapshotSeq = 0
            self.lastPlaybackSeq = 0
            self.lastProgressSeq = 0
            self.audio.resetSeq()
            self.link.send(.requestSnapshot)
            self.link.send(.requestAudioSettings)
        }
        link.onDisconnected = { [weak self] in self?.clear() }
    }

    /// Drop the mirror when the link goes down. The UI hides it anyway (see
    /// MainScreenView), and discarding it means a reconnect can't flash the old
    /// queue in the instant before the fresh snapshot lands.
    private func clear() {
        items = []
        localIDs = [:]
        handles = [:]
        playback = RemotePlaybackState()
        progressBase = nil
        lastSnapshotSeq = 0
        lastPlaybackSeq = 0
        lastProgressSeq = 0
        audio.clear()
    }

    // MARK: - Read-throughs for the UI

    var anchorID: UUID? { items.first(where: { $0.isAnchor })?.id }
    var currentItemID: UUID? { playback.currentItemID.flatMap { localIDs[$0] } }

    /// Position of the current track, advanced from the local clock between the
    /// receiver's ten-second corrections. The row re-reads this on its own timeline
    /// tick, so the countdown runs smoothly on a fraction of the old traffic.
    var elapsed: TimeInterval {
        guard let base = progressBase else { return 0 }
        guard playback.isPlaying || playback.isFadingOut else { return base.elapsed }
        let running = base.elapsed + Date().timeIntervalSince(base.at)
        return duration > 0 ? min(running, duration) : running
    }

    var duration: TimeInterval { playback.duration }

    // MARK: - Inbound state

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .snapshot(let snapshot):
            guard snapshot.seq > lastSnapshotSeq else { return }
            guard let merged = merge(snapshot.items, anchor: snapshot.anchor) else {
                // A row arrived without text that we have no text for — our mirror and
                // the receiver's idea of it have diverged. Ask for the full picture
                // rather than rendering blank rows.
                ptLog("[RemoteQueue] unresolvable row — requesting full resync")
                link.send(.requestSnapshot)
                return
            }
            lastSnapshotSeq = snapshot.seq
            items = merged
            pruneIdentities()
            applyPlayback(snapshot.playback, seq: snapshot.seq)
        case .delta(let delta):
            guard delta.seq > lastSnapshotSeq else { return }
            // The base must be exactly what we hold. If it isn't — a snapshot we
            // never got, a delta that arrived out of order — applying it would leave
            // a mirror quietly wrong, so ask for the whole queue instead.
            guard delta.baseSeq == lastSnapshotSeq, let updated = applying(delta) else {
                ptLog("[RemoteQueue] delta doesn't fit the mirror — requesting full resync")
                link.send(.requestSnapshot)
                return
            }
            lastSnapshotSeq = delta.seq
            items = updated
            pruneIdentities()
            applyPlayback(delta.playback, seq: delta.seq)
        case .playbackState(let update):
            applyPlayback(update.playback, seq: update.seq)
        case .progress(let progress):
            guard progress.seq > lastProgressSeq else { return }
            lastProgressSeq = progress.seq
            progressBase = (progress.elapsed, Date())
        case .addTrackResult(_, let failed):
            noteAddResult(failed: failed)
        case .audioSettings(let settings):
            audio.apply(settings)
        case .requestPlay, .stopWithFade, .resumeFromFade,
             .setAnchor, .move, .removeItems, .addTracks, .requestSnapshot,
             .setEQEnabled, .setEQBand, .resetEQ, .setVolume, .requestAudioSettings:
            break   // not consumed by the sender
        case .goodbye:
            break   // PeerLink acts on it (stops auto-reconnect); the mirror clears
                    // when the session then drops.
        }
    }

    /// Playback arrives two ways — inside a snapshot, and on its own when only the
    /// engine changed. One seq guard across both keeps the newer of the two.
    private func applyPlayback(_ state: RemotePlaybackState, seq: UInt64) {
        guard seq > lastPlaybackSeq else { return }
        lastPlaybackSeq = seq
        // A different track restarts the countdown. Rebasing at zero rather than
        // discarding the base matters because a transition's own position update can
        // be lost — the countdown then starts from the truth for a new track instead
        // of reading zero until the next correction.
        if state.currentItemID != playback.currentItemID { progressBase = (0, Date()) }
        playback = state
    }

    /// Fill in the rows the receiver sent without text, from the mirror we already
    /// hold. Returns nil if any such row is unknown to us — the caller resyncs.
    private func merge(_ incoming: [RemoteQueueItem], anchor: RowHandle?) -> [MirrorRow]? {
        let known = Dictionary(items.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [MirrorRow] = []
        merged.reserveCapacity(incoming.count)
        for row in incoming {
            let text: (title: String?, artist: String?, detail: String?)
            if row.hasText {
                text = (row.title, row.artist, row.detail)
            } else if let cached = known[row.id] {
                text = (cached.title, cached.artist, cached.detail)
            } else {
                return nil
            }
            merged.append(MirrorRow(id: localID(for: row.id), handle: row.id,
                                    title: text.title, artist: text.artist, detail: text.detail,
                                    isAnchor: row.id == anchor))
        }
        return merged
    }

    /// Rebuild the mirror from an edit script: drop the removed rows, then place
    /// each insertion at its final index in ascending order — by which point every
    /// earlier position is already settled. Returns nil if the script doesn't fit
    /// what we hold, and the caller resyncs rather than showing a wrong queue.
    private func applying(_ delta: RemoteQueueDelta) -> [MirrorRow]? {
        let known = Dictionary(items.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
        let gone = Set(delta.removed)
        var rows = items.filter { !gone.contains($0.handle) }
        for insertion in delta.inserted.sorted(by: { $0.at < $1.at }) {
            let row = insertion.item
            let text: (title: String?, artist: String?, detail: String?)
            if row.hasText {
                text = (row.title, row.artist, row.detail)
            } else if let cached = known[row.id] {
                // A row that only moved: we were told its name once already.
                text = (cached.title, cached.artist, cached.detail)
            } else {
                return nil
            }
            guard insertion.at <= rows.count else { return nil }
            rows.insert(MirrorRow(id: localID(for: row.id), handle: row.id,
                                  title: text.title, artist: text.artist, detail: text.detail,
                                  isAnchor: false), at: insertion.at)
        }
        // The count the receiver expects us to end on — a silent divergence here
        // would otherwise last until the next reconnect.
        guard rows.count == delta.count else { return nil }
        // The anchor arrives absolute, so restamp every row from it.
        return rows.map { MirrorRow(id: $0.id, handle: $0.handle, title: $0.title,
                                    artist: $0.artist, detail: $0.detail,
                                    isAnchor: $0.handle == delta.anchor) }
    }

    /// The view-facing identity for a handle, minted on first sight and stable for
    /// as long as the row stays in the queue — so SwiftUI keeps row state across
    /// snapshots rather than treating every update as a new list.
    private func localID(for handle: RowHandle) -> UUID {
        if let existing = localIDs[handle] { return existing }
        let id = UUID()
        localIDs[handle] = id
        handles[id] = handle
        return id
    }

    private func pruneIdentities() {
        let live = Set(items.map(\.handle))
        localIDs = localIDs.filter { live.contains($0.key) }
        handles = handles.filter { live.contains($0.value) }
    }

    /// Surface a brief notice when the receiver couldn't resolve some adds. Runs on
    /// main (PeerLink delivers on main); auto-clears after a few seconds.
    private func noteAddResult(failed: Int) {
        guard failed > 0 else { return }
        let notice = failed == 1
            ? "1 track couldn’t be added — not found on the receiver."
            : "\(failed) tracks couldn’t be added — not found on the receiver."
        addFailureNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.addFailureNotice == notice { self?.addFailureNotice = nil }
        }
    }

    // MARK: - Outbound intents (commands)

    func requestPlay(id: UUID) {
        guard let handle = handles[id] else { return }
        link.send(.requestPlay(itemID: handle))
    }

    /// A nil id clears the anchor; a row we have no handle for is a row that has
    /// already gone, so the command is dropped rather than sent as a clear.
    func setAnchor(id: UUID?) {
        guard let id else { return link.send(.setAnchor(itemID: nil)) }
        guard let handle = handles[id] else { return }
        link.send(.setAnchor(itemID: handle))
    }

    func move(ids: [UUID], toOffset: Int) {
        let moved = ids.compactMap { handles[$0] }
        guard moved.count == ids.count else { return }
        link.send(.move(itemIDs: moved, toOffset: toOffset))
    }

    func removeItems(ids: [UUID]) {
        let removed = ids.compactMap { handles[$0] }
        guard !removed.isEmpty else { return }
        link.send(.removeItems(itemIDs: removed))
    }
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
