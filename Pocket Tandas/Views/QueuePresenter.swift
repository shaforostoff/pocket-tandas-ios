// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueuePresenter.swift
//  Pocket Tandas
//
//  Lets QueueView render either the local PlayQueue (taps drive the local engine)
//  or the mirror of a remote receiver's queue (taps send commands) with one set
//  of row UI. Presenters are value types holding references to the underlying
//  @Observable sources; reading their computed properties inside a SwiftUI body
//  registers the right observation dependencies, so the view updates as the queue
//  or playback state changes.
//

import Foundation

/// View-model for one queue row, identical for the local and remote sources.
struct QueueRowVM: Identifiable, Hashable {
    let id: UUID
    let title: String
    let artist: String?
    let detail: String?
    let isCurrent: Bool
    let isFading: Bool
    let isAnchor: Bool
}

protocol QueuePresenting {
    var rows: [QueueRowVM] { get }
    var isRemote: Bool { get }
    /// Live position of the current track, read each timeline tick by the row.
    var elapsed: TimeInterval { get }
    var duration: TimeInterval { get }
    func requestPlay(_ id: UUID)
    func setAnchor(_ id: UUID?)
    func move(ids: [UUID], toOffset: Int)
    func remove(ids: [UUID])
}

/// The local play queue driven by the on-device engine — today's behaviour.
struct LocalQueuePresenter: QueuePresenting {
    let queue: PlayQueue
    let engine: PlaybackEngine
    let metadata: MetadataService

    var isRemote: Bool { false }
    var elapsed: TimeInterval { engine.currentElapsed }
    var duration: TimeInterval { engine.currentDuration }

    var rows: [QueueRowVM] {
        let currentID = engine.state.currentItemID
        let fading = engine.state.isFadingOut
        let anchorID = queue.anchorID
        return queue.items.map { item in
            let snapshot = metadata.snapshot(forKey: item.trackKey)
            let display: TrackDisplay
            if let snapshot, !snapshot.isEmpty {
                display = TrackDisplay(metadata: snapshot, fallback: item.filename)
            } else {
                display = TrackDisplay(filename: item.filename)
            }
            let isCurrent = item.id == currentID
            return QueueRowVM(id: item.id, title: display.titleLine, artist: display.artistLine,
                              detail: display.detailLine, isCurrent: isCurrent,
                              isFading: isCurrent && fading, isAnchor: item.id == anchorID)
        }
    }

    func requestPlay(_ id: UUID) {
        if let item = queue.item(withID: id) { engine.requestPlay(item) }
    }
    func setAnchor(_ id: UUID?) { queue.setAnchor(id) }
    func move(ids: [UUID], toOffset: Int) {
        let offsets = ids.compactMap { queue.index(of: $0) }
        guard !offsets.isEmpty else { return }
        queue.move(fromOffsets: IndexSet(offsets), toOffset: toOffset, pinnedID: engine.state.currentItemID)
    }
    func remove(ids: [UUID]) {
        let offsets = ids.compactMap { queue.index(of: $0) }
        guard !offsets.isEmpty else { return }
        queue.remove(atOffsets: IndexSet(offsets))
    }
}

/// The Remote Send mirror: rows come straight from the receiver's broadcast and
/// the mutating actions send commands (the change comes back as a new snapshot).
struct RemoteQueuePresenter: QueuePresenting {
    let remote: RemoteQueue

    var isRemote: Bool { true }
    var elapsed: TimeInterval { remote.progress.elapsed }
    var duration: TimeInterval { remote.progress.duration }

    var rows: [QueueRowVM] {
        let currentID = remote.playback.currentItemID
        let fading = remote.playback.isFadingOut
        return remote.items.map { item in
            let isCurrent = item.id == currentID
            return QueueRowVM(id: item.id, title: item.title, artist: item.artist,
                              detail: item.detail, isCurrent: isCurrent,
                              isFading: isCurrent && fading, isAnchor: item.isAnchor)
        }
    }

    func requestPlay(_ id: UUID) { remote.requestPlay(id: id) }
    func setAnchor(_ id: UUID?) { remote.setAnchor(id: id) }
    func move(ids: [UUID], toOffset: Int) { remote.move(ids: ids, toOffset: toOffset) }
    func remove(ids: [UUID]) { remote.removeItems(ids: ids) }
}
