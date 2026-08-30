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
///
/// The display text is sent ONCE PER CONNECTION per row: the receiver remembers
/// what it has told this sender about each id, and thereafter sends the row with
/// the text fields omitted (Codable drops nil keys, so a repeat row is ~60 bytes
/// instead of ~200). Text reappears whenever it is genuinely new — a freshly added
/// track, or a row whose metadata scan has since filled in a real title. The
/// sender merges nil fields against its own mirror; if it ever meets an id it has
/// no text for it asks for a full resync rather than showing a blank row.
struct RemoteQueueItem: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String?
    let artist: String?
    let detail: String?      // right-aligned line: BPM · Genre · Date
    let isAnchor: Bool

    /// True when this row carries its display text (a new or changed row).
    var hasText: Bool { title != nil }
}

/// Playback state on its own, sent whenever the engine changes without the queue
/// changing — a track transition, Stop, Resume, pause. Keeping it out of
/// RemoteSnapshot is what stops every song change retransmitting the whole queue.
struct RemotePlaybackUpdate: Codable, Hashable {
    var playback: RemotePlaybackState
    var seq: UInt64
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

/// The receiver's audio-chain settings (EQ + master volume), broadcast to the
/// sender on connect and on every change so the Remote Control screen's EQ and
/// Volume panels show what the speakers are actually doing. `seq` shares the
/// coordinator's counter, so stale updates can be dropped.
///
/// Version-tolerant like TrackAddRequest: every field has a default and decoding
/// tolerates a missing key, so a peer running an older/newer build still decodes.
struct RemoteAudioSettings: Codable, Hashable {
    var eqEnabled: Bool = true
    var bands: [EQBand] = []
    var volume: Float = 1.0
    var seq: UInt64 = 0

    init(eqEnabled: Bool = true, bands: [EQBand] = [], volume: Float = 1.0, seq: UInt64 = 0) {
        self.eqEnabled = eqEnabled
        self.bands = bands
        self.volume = volume
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
    }
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
