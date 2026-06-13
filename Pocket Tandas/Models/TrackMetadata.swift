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

    /// File modification date at the time of the scan, used for staleness checks.
    var sourceModDate: Date
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
         sourceModDate: Date = .distantPast,
         lastScanned: Date = .now,
         fileBookmark: Data? = nil) {
        self.trackKey = trackKey
        self.title = title
        self.artist = artist
        self.genre = genre
        self.dateText = dateText
        self.year = year
        self.bpm = bpm
        self.sourceModDate = sourceModDate
        self.lastScanned = lastScanned
        self.fileBookmark = fileBookmark
    }
}
