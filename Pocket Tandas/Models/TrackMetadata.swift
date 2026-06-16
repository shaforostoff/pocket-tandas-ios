// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackMetadata.swift
//  Pocket Tandas
//
//  Durable, on-disk metadata cache for audio files. Keyed by a stable
//  identifier (see StableTrackID) so cache entries survive the base folder
//  being re-granted at a different absolute path.
//

import Foundation
import SwiftData

@Model
final class TrackMetadata {
    /// Stable identifier: base-relative path + filename + file size.
    @Attribute(.unique) var trackKey: String

    var title: String?
    var artist: String?
    var genre: String?

    /// Normalized "YYYY-MM-DD" or "YYYY". Tango dates are imprecise, so the
    /// text form is the source of truth; `year` is a parsed convenience.
    var dateText: String?
    var year: Int?

    var bpm: Int?

    /// ReplayGain track gain in dB (album gain is ignored). Applied as a
    /// per-track playback volume scale by the engine. Optional, so existing
    /// cache entries migrate in place (re-scanned files pick it up).
    var trackGainDB: Double?

    /// File modification date + size at the time of the scan; staleness checks
    /// re-scan when either changes. `fileSize` is optional so existing rows migrate
    /// in place (older entries predate it and are re-scanned anyway).
    var sourceModDate: Date
    var fileSize: Int?
    var lastScanned: Date

    /// Optional per-file security-scoped bookmark for files referenced by a
    /// playlist that live outside the current base-folder tree.
    var fileBookmark: Data?

    init(trackKey: String,
         title: String? = nil,
         artist: String? = nil,
         genre: String? = nil,
         dateText: String? = nil,
         year: Int? = nil,
         bpm: Int? = nil,
         trackGainDB: Double? = nil,
         sourceModDate: Date = .distantPast,
         fileSize: Int? = nil,
         lastScanned: Date = .now,
         fileBookmark: Data? = nil) {
        self.trackKey = trackKey
        self.title = title
        self.artist = artist
        self.genre = genre
        self.dateText = dateText
        self.year = year
        self.bpm = bpm
        self.trackGainDB = trackGainDB
        self.sourceModDate = sourceModDate
        self.fileSize = fileSize
        self.lastScanned = lastScanned
        self.fileBookmark = fileBookmark
    }
}
