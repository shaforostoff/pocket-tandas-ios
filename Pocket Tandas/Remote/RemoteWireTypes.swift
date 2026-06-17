// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteWireTypes.swift
//  Pocket Tandas
//
//  Value types exchanged between two phones in Remote Send / Remote Receive
//  modes. The receiver pre-resolves display fields (title/artist/detail) from its
//  own metadata cache so the sender can render the mirror with no metadata of its
//  own. Heavy `RemoteSnapshot` (structural change) is kept separate from the
//  lightweight `RemoteProgress` (timer ticks) so the live countdown doesn't
//  reserialize the whole queue. A monotonic `seq` lets the sender drop stale or
//  out-of-order messages.
//

import Foundation

/// One queue entry as seen over the wire. `id` is the receiver's QueueItem.id —
/// commands address rows by this identity, never by index.
struct RemoteQueueItem: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let artist: String?
    let detail: String?      // right-aligned line: BPM · Genre · Date
    let isAnchor: Bool
}

/// Mirror of PlaybackState for the wire (engine internals omitted).
struct RemotePlaybackState: Codable, Hashable {
    enum Kind: String, Codable { case idle, playing, fadingOut, paused }
    var kind: Kind = .idle
    var currentItemID: UUID?

    var isPlaying: Bool { kind == .playing }
    var isFadingOut: Bool { kind == .fadingOut }
    var isPaused: Bool { kind == .paused }
}

/// Frequent, cheap position update for the current track (sent on a timer).
struct RemoteProgress: Codable, Hashable {
    var itemID: UUID?
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var seq: UInt64 = 0
}

/// Full authoritative state of the receiver's queue + playback, sent on any
/// structural change.
struct RemoteSnapshot: Codable, Hashable {
    var items: [RemoteQueueItem]
    var playback: RemotePlaybackState
    var seq: UInt64
}

/// A request to add a track on the receiver (Milestone 2). The receiver resolves
/// it to a local file via RemoteTrackResolver. `relativePath` is the sender's
/// base-relative path; the metadata fields are the sender's cached values, used
/// for the metadata-match fallback when paths/extensions don't line up.
struct TrackAddRequest: Codable, Hashable {
    let relativePath: String
    let artist: String?
    let title: String?
    let dateText: String?
    let year: Int?
}
