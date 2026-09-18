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
//  The detail line is kept as its separate fields rather than as finished text,
//  because each one carries where its value came from: BPM and genre may be what
//  the tags said or what the analyser measured (see TrackAnalysis), and the row
//  tints the measured ones. Everything that only needs the text reads
//  `detailLine`.
//

import Foundation

struct TrackDisplay {
    /// One field of the right-aligned detail line.
    struct DetailPart: Hashable {
        let text: String
        /// True when the app measured this value for itself because the file's
        /// tags had none — the row shows it in the measured tint.
        let isEstimated: Bool

        /// A detail line that arrived as finished text, with no idea left of how
        /// it was arrived at: the Remote Send mirror, where the sending device
        /// resolved the fields and only the string crossed the wire.
        static func opaque(_ text: String?) -> [DetailPart] {
            guard let text, !text.isEmpty else { return [] }
            return [DetailPart(text: text, isEstimated: false)]
        }
    }

    let titleLine: String
    let artistLine: String?
    let detailParts: [DetailPart]   // right-aligned: BPM · Genre · Date

    /// The detail line as one string, for everything that cannot carry the
    /// fields apart (the Remote Send wire, tests, logs).
    var detailLine: String? {
        detailParts.isEmpty ? nil : detailParts.map(\.text).joined(separator: " · ")
    }

    init(metadata: TrackMetadataSnapshot, fallback: String) {
        titleLine = metadata.title ?? fallback
        artistLine = metadata.artist

        var parts: [DetailPart] = []
        // Three is the ceiling, and reserving it is worth a line here in a way it
        // is not for the big accumulators elsewhere. An empty array grown by
        // append reallocates at 1, 2 and 4, so a three-part line costs three
        // allocations — and the queue rebuilds one of these for EVERY row, every
        // time its view-model is read. Reserving once took a 120-row queue's
        // detail lines from 142µs to 43µs. (Measured the same trick on the
        // 2000-element listing arrays: there the element construction dominates
        // and reserving is noise, so they are deliberately left alone.)
        parts.reserveCapacity(3)
        if let bpm = metadata.bpm {
            parts.append(DetailPart(text: "\(bpm) BPM", isEstimated: metadata.isBPMEstimated))
        }
        if let genre = metadata.genre, !genre.isEmpty {
            parts.append(DetailPart(text: genre, isEstimated: metadata.isGenreEstimated))
        }
        if let date = metadata.dateText, !date.isEmpty {
            // Dates are only ever read from tags; there is nothing to measure.
            parts.append(DetailPart(text: date, isEstimated: false))
        }
        detailParts = parts
    }

    init(filename: String) {
        titleLine = filename
        artistLine = nil
        detailParts = []
    }

    /// Build directly from already-resolved lines — used by the queue row, whose
    /// view-model carries the parts, and by the Remote Send mirror through
    /// `DetailPart.opaque`.
    init(titleLine: String, artistLine: String?, detail: [DetailPart]) {
        self.titleLine = titleLine
        self.artistLine = artistLine
        self.detailParts = detail
    }

    var hasSecondRow: Bool { artistLine != nil || !detailParts.isEmpty }
}
