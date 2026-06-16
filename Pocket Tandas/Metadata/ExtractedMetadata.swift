// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  ExtractedMetadata.swift
//  Pocket Tandas
//
//  Plain result of reading a file's metadata. Mapped into TrackMetadata (cache)
//  and TrackMetadataSnapshot (UI) by the service.
//

import Foundation

struct ExtractedMetadata: Sendable {
    var title: String?
    var artist: String?
    var genre: String?
    var dateText: String?
    var year: Int?
    var bpm: Int?

    /// ReplayGain track gain in dB (album gain is ignored). nil when absent.
    var trackGainDB: Double?

    /// Map the extracted tags into a UI snapshot, stamping the source-file
    /// identity (mod-date + size) used later for staleness checks.
    func snapshot(sourceModDate: Date, fileSize: Int) -> TrackMetadataSnapshot {
        TrackMetadataSnapshot(title: title, artist: artist, genre: genre,
                              dateText: dateText, year: year, bpm: bpm,
                              trackGainDB: trackGainDB,
                              sourceModDate: sourceModDate, fileSize: fileSize)
    }
}
