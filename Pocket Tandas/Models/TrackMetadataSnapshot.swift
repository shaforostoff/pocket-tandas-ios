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
//  BPM and genre have two possible sources: what the file's tags say, and what the
//  analyser measured when they said nothing (see TrackAnalysis). Both are carried
//  separately and resolved by `bpm` and `genre` below, so a tag added later wins
//  automatically and nothing downstream has to know there was a choice to make.
//

import Foundation

struct TrackMetadataSnapshot: Hashable {
    var title: String?
    var artist: String?
    /// Genre exactly as the tags carry it — nil, or the empty string, when they
    /// carry none. Read `genre` to display it.
    var taggedGenre: String?
    var dateText: String?
    var year: Int?
    /// BPM exactly as the tags carry it. Read `bpm` to display it.
    var taggedBPM: Int?

    /// ReplayGain track gain in dB, applied to playback volume — not shown in the
    /// UI, so it is intentionally excluded from `isEmpty` (which gates the
    /// metadata detail line).
    var trackGainDB: Double?

    /// Measured tempo, on the metrical level a dancer taps. Only ever filled in
    /// for a track whose tags left a gap, and only ever shown where they still do.
    var estimatedBPM: Double?
    /// Measured rhythm, already narrowed to "Tango", "Vals" or "Milonga" — see
    /// AnalyzedRhythm for why nothing else gets a name.
    var estimatedGenre: String?

    /// Source-file identity used only for staleness detection (re-scan when either
    /// changes). Folded in here so one `snapshots` map carries it, rather than a
    /// parallel mod-date map. Defaulted so display/preview call sites can omit it.
    var sourceModDate: Date = .distantPast
    var fileSize: Int = 0

    /// The BPM to show: the tag where there is one, otherwise the measurement,
    /// rounded — a dancer taps whole numbers.
    var bpm: Int? { taggedBPM ?? estimatedBPM.map { Int($0.rounded()) } }

    /// The genre to show: the tag where there is one, otherwise the measurement.
    /// An empty tag counts as no tag; a file whose genre field exists but is blank
    /// should not suppress what was measured.
    var genre: String? {
        if let taggedGenre, !taggedGenre.isEmpty { return taggedGenre }
        return estimatedGenre
    }

    var isEmpty: Bool {
        title == nil && artist == nil && genre == nil && dateText == nil && year == nil && bpm == nil
    }
}
