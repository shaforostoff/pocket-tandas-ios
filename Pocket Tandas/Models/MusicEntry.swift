// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicEntry.swift
//  Pocket Tandas
//
//  One row in the Music-library browser — the `LibraryEntry` analogue. Either a
//  drillable container (artist/album/genre/playlist) or a track. A track carries a
//  TrackMetadataSnapshot built straight from its MPMediaItem (no file scan), so it
//  renders through the same BrowserRowView / TrackDisplay as a file row, plus a
//  MusicTrackRef identifying the library track for enqueue / prelisten.
//

import Foundation
import MediaPlayer

/// The MPMediaItem fields a browser row needs, copied out once when the listing is
/// built. Rows hold this rather than the MPMediaItem so browsing a large category
/// doesn't pin one library object per row — each MPMediaItem caches every property
/// ever read from it, so a thousand-row list holds a thousand of those caches.
///
/// `assetURL` is deliberately NOT among these fields: it is an expensive per-item
/// lookup, and the listing is rebuilt on every filter keystroke. It is resolved
/// from `persistentID` (see MusicLibrary.item(forPersistentID:)) only when a track
/// is actually auditioned or enqueued.
struct MusicTrackRef: Hashable {
    let persistentID: UInt64
    let title: String
    let album: String?
    let duration: TimeInterval

    init(_ item: MPMediaItem) {
        persistentID = item.persistentID
        title = item.title ?? "Unknown"
        album = item.albumTitle
        duration = item.playbackDuration
    }
}

struct MusicEntry: Identifiable {
    enum Kind {
        case container(MusicContainer)
        case track
    }
    /// Stable identity: the container token, or "medialib:<persistentID>" for a
    /// track (matches the QueueItem media key).
    let id: String
    let kind: Kind
    let title: String
    let systemImage: String
    let isNavigable: Bool
    /// Display metadata for a track row (nil for containers).
    let snapshot: TrackMetadataSnapshot?
    /// The library track this row stands for (nil for containers).
    let track: MusicTrackRef?
}

extension MusicEntry: Hashable {
    static func == (lhs: MusicEntry, rhs: MusicEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension TrackMetadataSnapshot {
    /// Build a display snapshot from a Music-library item's properties. There is no
    /// ReplayGain in the library, so `trackGainDB` is nil (engine defaults to unity).
    init(mediaItem item: MPMediaItem) {
        let year: Int? = item.releaseDate.map { Calendar.current.component(.year, from: $0) }
        self.init(title: item.title,
                  artist: item.artist,
                  genre: item.genre,
                  dateText: year.map(String.init),
                  year: year,
                  bpm: item.beatsPerMinute > 0 ? Int(item.beatsPerMinute) : nil,
                  trackGainDB: nil)
    }
}
