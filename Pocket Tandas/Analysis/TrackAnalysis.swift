// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackAnalysis.swift
//  Pocket Tandas
//
//  What the analyser measured for one track, and its durable cache.
//
//  Kept apart from TrackMetadata rather than folded into it, for three reasons:
//  a measurement is a property of the AUDIO where TrackMetadata caches the file's
//  TAGS, so a tag edit re-scans one and must not disturb the other; the two are
//  filled in by different passes at very different costs; and this table is keyed
//  loosely enough to hold Music-library items, which TrackMetadata deliberately
//  never stores.
//
//  Tags always win over what is here — see TrackMetadataSnapshot.
//

import Foundation
import SwiftData

/// One track's measurement, as the app is willing to state it: a tempo, and a
/// genre only where the classifier landed on a rhythm this app dances to.
struct TrackAnalysisResult: Hashable, Sendable {
    /// Tempo on the level a dancer taps — the beat for a tango, the bar for a
    /// vals or a milonga. nil when there was no beat to measure.
    var bpm: Double?
    /// "Tango", "Vals" or "Milonga", or nil for everything else. See
    /// `AnalyzedRhythm`.
    var genre: String?
    /// Classifier probability for the rhythm it settled on, 0…1 — including the
    /// ones `genre` drops, so a row that measured "Reggae" at 0.9 can be told
    /// from one that had no idea.
    var confidence: Double?

    /// True when the analysis ran but found nothing to say. Still worth storing:
    /// it is what stops the track being decoded again on every visit.
    var isEmpty: Bool { bpm == nil && genre == nil }
}

/// Durable cache of `TrackAnalysisResult`, keyed like the metadata cache (see
/// StableTrackID). A row exists once a track has been analysed, whether or not
/// anything came of it.
@Model
final class TrackAnalysis {
    @Attribute(.unique) var trackKey: String

    var bpm: Double?
    var genre: String?
    var confidence: Double?

    /// When the measurement was taken. Not read by anything today; it is what a
    /// future "re-measure everything older than X" would key off, and it makes a
    /// row that stored nothing distinguishable from an absent one in the store.
    var analyzedAt: Date

    init(trackKey: String, result: TrackAnalysisResult, analyzedAt: Date = .now) {
        self.trackKey = trackKey
        self.bpm = result.bpm
        self.genre = result.genre
        self.confidence = result.confidence
        self.analyzedAt = analyzedAt
    }

    var result: TrackAnalysisResult {
        TrackAnalysisResult(bpm: bpm, genre: genre, confidence: confidence)
    }

    func update(with result: TrackAnalysisResult, analyzedAt: Date = .now) {
        self.bpm = result.bpm
        self.genre = result.genre
        self.confidence = result.confidence
        self.analyzedAt = analyzedAt
    }
}

/// The classifier's answer, narrowed to what this app will call a genre.
///
/// The core knows four rhythms and an "Other" that spans bossa to disco to
/// chacarera. Only the three a milonga is danced to are worth writing into a
/// genre field — a row reading "Other", or "Reggae" for a badly tracked tango,
/// tells a DJ nothing and is worse than a blank, which at least reads as "not
/// known". So everything else maps to nil and the field stays empty.
enum AnalyzedRhythm {
    static func genre(for rhythm: PTRhythmClass) -> String? {
        switch rhythm {
        case .tango:   return "Tango"
        case .vals:    return "Vals"
        case .milonga: return "Milonga"
        default:       return nil   // .reggae, .other, and anything added later
        }
    }
}
