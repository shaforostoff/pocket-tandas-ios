// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueItem.swift
//  Pocket Tandas
//
//  One entry in the play queue. Identity is a per-insertion UUID, so the same
//  track can appear multiple times and reorder/remove independently.
//
//  A track is either a FILE (a URL on disk, played by AVAudioFile + scheduleFile,
//  gapless) or a MEDIA-LIBRARY item (a reference to a device Music-library track,
//  played by AVAssetReader streaming straight from `ipod-library://` — never
//  copied into the app). File metadata is looked up live from MetadataService by
//  `trackKey`; media metadata has no file to scan, so it is captured up front from
//  the MPMediaItem and carried on `mediaSnapshot`.
//

import Foundation

struct QueueItem: Identifiable, Hashable {
    let id = UUID()

    enum Source: Hashable {
        case file(url: URL)
        case mediaLibrary(MediaRef)
    }
    let source: Source

    /// Metadata cache key. Files: a base-relative path or "name|size" (see
    /// StableTrackID). Media: "medialib:<persistentID>", which can't collide with
    /// a file key.
    let trackKey: String

    /// Display metadata captured from the MPMediaItem at enqueue (there is no file
    /// to scan). Nil for file items, whose metadata MetadataService owns.
    let mediaSnapshot: TrackMetadataSnapshot?

    /// A file item. Existing call sites use this initializer unchanged.
    init(url: URL, trackKey: String) {
        self.source = .file(url: url)
        self.trackKey = trackKey
        self.mediaSnapshot = nil
    }

    /// A Music-library item, played by reference. `trackKey` is derived from the
    /// persistent id so the same library track maps to one stable key.
    init(media ref: MediaRef, snapshot: TrackMetadataSnapshot) {
        self.source = .mediaLibrary(ref)
        self.trackKey = "medialib:\(ref.persistentID)"
        self.mediaSnapshot = snapshot
    }

    var isMediaLibrary: Bool {
        if case .mediaLibrary = source { return true }
        return false
    }

    /// The library reference, when this is a media item.
    var mediaRef: MediaRef? {
        if case .mediaLibrary(let ref) = source { return ref }
        return nil
    }

    /// The playable URL: the file URL, or the `ipod-library://` asset URL for a
    /// media item. Nil only for a media item with no readable asset (DRM/cloud, or
    /// not yet re-resolved after a cold launch).
    var url: URL? {
        switch source {
        case .file(let url): return url
        case .mediaLibrary(let ref): return ref.assetURL
        }
    }

    /// The disk URL only when this is a file item — for the file-only metadata
    /// scan and playlist writing (media items have neither).
    var fileURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }

    /// Best-effort label for logging and the no-metadata fallback.
    var filename: String {
        switch source {
        case .file(let url): return url.lastPathComponent
        case .mediaLibrary(let ref): return ref.displayTitle
        }
    }
}

/// A reference to a device Music-library track, played without copying.
struct MediaRef: Hashable {
    /// MPMediaItem.persistentID — stable for this track within THIS device's
    /// library only. It differs per device, so it must NEVER be sent over the
    /// remote link (cross-device matching is by metadata).
    let persistentID: UInt64
    /// `ipod-library://…` asset URL for a non-DRM track; nil for DRM/cloud items
    /// or before re-resolution at launch.
    let assetURL: URL?
    /// Title fallback for logging and no-snapshot rows.
    let displayTitle: String
    /// MPMediaItem.playbackDuration — authoritative length, no AVAudioFile probe.
    let duration: TimeInterval
}
