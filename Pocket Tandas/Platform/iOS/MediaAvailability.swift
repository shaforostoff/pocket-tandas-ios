// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaAvailability.swift
//  Pocket Tandas
//
//  Why a Music-library track can't be played, and how to say so.
//
//  A nil `MPMediaItem.assetURL` — the thing every media playback path here trips
//  over — has two quite different causes, and only one of them is a dead end:
//
//   - The item is in the user's iCloud Music Library but hasn't been downloaded
//     to this phone (`isCloudItem`). Entirely fixable: download it in Music.
//   - The item is FairPlay-protected (`hasProtectedAsset`): Apple Music tracks,
//     and iTunes Store purchases from before it went DRM-free. iOS decodes those
//     inside a protected path and never hands the samples to another process, so
//     PlaybackEngine's AVAssetReader → AVAudioEngine chain (and with it the EQ,
//     ReplayGain, fades and cue split) can't touch them at any price.
//
//  Treating both as "skip silently" makes the app look broken. These types let a
//  skipped add or audition explain itself instead.
//

import Foundation
import MediaPlayer

/// Why a library track can't be played by this app.
enum MediaUnavailability: Hashable {
    /// In iCloud Music Library, not on this device. The user can fix this.
    case notDownloaded
    /// DRM-protected. Nothing the user or the app can do.
    case protected
    /// No asset and neither flag explains it — e.g. the item was removed from the
    /// library between the listing being built and the row being tapped.
    case unplayable

    var alertTitle: String {
        switch self {
        case .notDownloaded: return "Not Downloaded"
        case .protected: return "Protected Track"
        case .unplayable: return "Track Unavailable"
        }
    }

    /// Wording for a single named track.
    func message(for title: String) -> String {
        switch self {
        case .notDownloaded:
            return "“\(title)” is in your iCloud Music Library but isn't on this "
                 + "phone. Download it in the Music app, then add it here."
        case .protected:
            return "“\(title)” is copy-protected, so other apps can't play it. "
                 + "Apple Music tracks and older iTunes Store purchases are "
                 + "protected; a DRM-free copy of the same recording will work."
        case .unplayable:
            return "“\(title)” has no playable file on this phone."
        }
    }

    /// Wording for a group of tracks sharing this reason. Phrased without a verb
    /// so one form covers both "1 track" and "12 tracks".
    func summary(count: Int) -> String {
        let subject = count == 1 ? "1 track" : "\(count) tracks"
        switch self {
        case .notDownloaded:
            return "\(subject) not on this phone — download in the Music app, "
                 + "then add here."
        case .protected:
            return "\(subject) copy-protected — Apple Music and older iTunes "
                 + "purchases can't be played by other apps."
        case .unplayable:
            return "\(subject) with no playable file on this phone."
        }
    }
}

extension MPMediaItem {
    /// Why this item can't be played, or nil if it can.
    ///
    /// Order matters: an Apple Music track that *has* been downloaded is both a
    /// cloud item and protected, and "protected" is the truthful answer — telling
    /// the user to download something they already downloaded would send them in
    /// a circle. Both flags are only read once `assetURL` has already come back
    /// nil, so the happy path stays a single (already expensive) lookup.
    var unavailability: MediaUnavailability? {
        guard assetURL == nil else { return nil }
        if hasProtectedAsset { return .protected }
        if isCloudItem { return .notDownloaded }
        return .unplayable
    }
}

/// What an add or audition skipped, grouped so a single alert can explain a whole
/// album's worth of skips without listing every track.
struct MediaSkipReport {
    private var titles: [MediaUnavailability: [String]] = [:]

    init() {}

    /// A report about one named track.
    init(title: String, reason: MediaUnavailability) {
        titles[reason] = [title]
    }

    var isEmpty: Bool { titles.isEmpty }

    mutating func add(title: String, reason: MediaUnavailability) {
        titles[reason, default: []].append(title)
    }

    /// The reasons present, in a stable order so the alert doesn't reshuffle
    /// itself between two identical adds (dictionary order isn't).
    private var reasons: [MediaUnavailability] {
        [.notDownloaded, .protected, .unplayable].filter { titles[$0]?.isEmpty == false }
    }

    private var total: Int { titles.values.reduce(0) { $0 + $1.count } }

    /// One reason → name it; several → stay neutral in the title and let the
    /// message break the counts down.
    var alertTitle: String {
        reasons.count == 1 ? reasons[0].alertTitle : "Some Tracks Skipped"
    }

    var message: String {
        // A single track is worth naming; a batch is not.
        if total == 1, let reason = reasons.first, let title = titles[reason]?.first {
            return reason.message(for: title)
        }
        return reasons.map { $0.summary(count: titles[$0]?.count ?? 0) }
            .joined(separator: "\n\n")
    }
}
