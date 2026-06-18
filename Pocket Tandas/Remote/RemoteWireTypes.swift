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

/// A request to add a track on the receiver. The receiver resolves it via
/// RemoteTrackResolver to either a local file (file source) or a track in its own
/// Music library (media source). For files, `relativePath` is the sender's
/// base-relative path and the metadata fields drive the fallback match. For media,
/// there is no shared path — `persistentID` differs per device — so matching is by
/// title/artist(/album/year/duration) against the receiver's synced library.
///
/// JSON/version-tolerant: every field is optional and `source` defaults to `.file`
/// (via the custom decoder) so a request from an older sender still decodes.
struct TrackAddRequest: Codable, Hashable {
    enum Source: String, Codable { case file, mediaLibrary }

    var source: Source = .file
    var relativePath: String?       // file source only
    var artist: String?
    var title: String?
    var dateText: String?
    var year: Int?
    var album: String?              // media: extra MPMediaQuery disambiguator
    var durationHint: TimeInterval? // media: tie-break near-equal-length matches

    init(source: Source = .file, relativePath: String? = nil, artist: String? = nil,
         title: String? = nil, dateText: String? = nil, year: Int? = nil,
         album: String? = nil, durationHint: TimeInterval? = nil) {
        self.source = source
        self.relativePath = relativePath
        self.artist = artist
        self.title = title
        self.dateText = dateText
        self.year = year
        self.album = album
        self.durationHint = durationHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent ?? default — synthesized Codable would treat a missing
        // `source` key as an error, so apply the .file default explicitly.
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .file
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        dateText = try c.decodeIfPresent(String.self, forKey: .dateText)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationHint = try c.decodeIfPresent(TimeInterval.self, forKey: .durationHint)
    }
}
