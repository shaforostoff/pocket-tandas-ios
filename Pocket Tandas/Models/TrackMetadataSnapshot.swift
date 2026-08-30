// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackMetadataSnapshot.swift
//  Pocket Tandas
//
//  Plain value snapshot of a track's cached metadata. Passed across boundaries
//  (lister, rows, queue) instead of the SwiftData @Model, which is reference-typed
//  and bound to a context.
//

import Foundation

struct TrackMetadataSnapshot: Hashable {
    var title: String?
    var artist: String?
    var genre: String?
    var dateText: String?
    var year: Int?
    var bpm: Int?

    /// ReplayGain track gain in dB, applied to playback volume — not shown in the
    /// UI, so it is intentionally excluded from `isEmpty` (which gates the
    /// metadata detail line).
    var trackGainDB: Double?

    /// Source-file identity used only for staleness detection (re-scan when either
    /// changes). Folded in here so one `snapshots` map carries it, rather than a
    /// parallel mod-date map. Defaulted so display/preview call sites can omit it.
    var sourceModDate: Date = .distantPast
    var fileSize: Int = 0

    var isEmpty: Bool {
        title == nil && artist == nil && genre == nil && dateText == nil && year == nil && bpm == nil
    }
}
