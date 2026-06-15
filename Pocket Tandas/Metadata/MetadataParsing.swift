// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataParsing.swift
//  Pocket Tandas
//
//  Pure (AVFoundation-free) parsing rules, kept separate so they can be unit
//  tested without audio files.
//
//  Date rule: use the date field if it holds a full YYYY-MM-DD. Otherwise (the
//  field is year-only or empty) look in the comment field for a YYYY-MM-DD and
//  use that. Otherwise fall back to the year alone from the date field.
//

import Foundation

enum MetadataParsing {
    struct ResolvedDate: Equatable {
        let dateText: String?
        let year: Int?
    }

    static func resolveDate(dateField: String?, commentField: String?) -> ResolvedDate {
        if let full = fullDate(in: dateField) {
            return ResolvedDate(dateText: full, year: Int(full.prefix(4)))
        }
        if let full = fullDate(in: commentField) {
            return ResolvedDate(dateText: full, year: Int(full.prefix(4)))
        }
        if let y = year(in: dateField) {
            return ResolvedDate(dateText: String(format: "%04d", y), year: y)
        }
        return ResolvedDate(dateText: nil, year: nil)
    }

    static func parseBPM(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var digits = ""
        for ch in raw {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard let n = Int(digits), n > 0, n < 1000 else { return nil }
        return n
    }

    /// ReplayGain *track* gain in dB, parsed from a freeform tag value such as
    /// "-2.33 dB" (also accepts "+1.5" or "6.00 dB" — the unit is optional).
    /// Implausible magnitudes (corrupt tags) are rejected so a bad value can't
    /// turn into an extreme playback volume.
    static func parseReplayGainGain(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let match = firstMatch(replayGainRegex, in: raw), let db = Double(match) else { return nil }
        guard db.isFinite, abs(db) <= 60 else { return nil }
        return db
    }

    // MARK: - Helpers

    // Leading boundary only, so an ISO timestamp like "1935-05-14T00:00:00"
    // still yields the date portion.
    private static let fullDateRegex = try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}"#)
    private static let yearRegex = try! NSRegularExpression(pattern: #"\b\d{4}\b"#)
    // Leading signed decimal, e.g. the "-2.33" in "-2.33 dB".
    private static let replayGainRegex = try! NSRegularExpression(pattern: #"[-+]?\d+(\.\d+)?"#)

    static func fullDate(in s: String?) -> String? {
        firstMatch(fullDateRegex, in: s)
    }

    static func year(in s: String?) -> Int? {
        guard let match = firstMatch(yearRegex, in: s) else { return nil }
        return Int(match)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in s: String?) -> String? {
        guard let s else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }
}
