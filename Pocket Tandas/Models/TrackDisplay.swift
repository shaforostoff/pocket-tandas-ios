// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackDisplay.swift
//  Pocket Tandas
//
//  Turns cached metadata (or a filename fallback) into the two display rows used
//  by both browser and queue rows:
//    Row 1: Title (left)
//    Row 2: Artist (left)  ·  BPM + Genre + Date (right)
//

import Foundation

struct TrackDisplay {
    let titleLine: String
    let artistLine: String?
    let detailLine: String?   // right-aligned: BPM · Genre · Date

    init(metadata: TrackMetadataSnapshot, fallback: String) {
        titleLine = metadata.title ?? fallback
        artistLine = metadata.artist

        var parts: [String] = []
        if let bpm = metadata.bpm { parts.append("\(bpm) BPM") }
        if let genre = metadata.genre, !genre.isEmpty { parts.append(genre) }
        if let date = metadata.dateText, !date.isEmpty { parts.append(date) }
        detailLine = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(filename: String) {
        titleLine = filename
        artistLine = nil
        detailLine = nil
    }

    var hasSecondRow: Bool { artistLine != nil || detailLine != nil }
}
