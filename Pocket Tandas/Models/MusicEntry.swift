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
//  renders through the same BrowserRowView / TrackDisplay as a file row, and the
//  MPMediaItem itself for enqueue / prelisten.
//

import Foundation
import MediaPlayer

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
    /// The library track, for enqueue / prelisten (nil for containers).
    let mediaItem: MPMediaItem?

    var assetURL: URL? { mediaItem?.assetURL }
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
