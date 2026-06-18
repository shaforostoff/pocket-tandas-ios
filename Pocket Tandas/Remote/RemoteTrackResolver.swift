// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteTrackResolver.swift
//  Pocket Tandas
//
//  Resolves a TrackAddRequest (from a Remote Send peer) to a local audio file
//  under the receiver's base folder, trying progressively looser matches:
//    1. the exact base-relative path (identical libraries — the common case);
//    2. the same folder + filename stem with any other supported audio extension;
//    3. a metadata match on title + artist (case/diacritic-insensitive), using
//       year only to disambiguate when several title+artist matches exist;
//    4. a recursive search for the filename stem (any supported audio extension).
//
//  Step 3 queries the durable SwiftData metadata cache via its own ModelContext
//  (created from the container) so it sees everything ever scanned, not just the
//  folders browsed this session — and stays off the main actor.
//

import Foundation
import SwiftData
import MediaPlayer

/// What a TrackAddRequest resolved to on the receiver: a local file, or a track in
/// the receiver's own Music library (played by reference, like a local media add).
enum ResolvedTrack {
    case file(URL)
    case media(MPMediaItem)
}

struct RemoteTrackResolver {
    let baseURL: URL?
    /// The metadata store, used only for the step-3 title/artist match. Optional so
    /// the filesystem steps can be unit-tested without a container.
    var container: ModelContainer?
    var fileManager: FileManager = .default

    func resolve(_ request: TrackAddRequest) -> ResolvedTrack? {
        switch request.source {
        case .file:
            // The base-folder requirement is a FILE concern: a media request must
            // resolve even on a receiver that has only a Music library.
            guard let baseURL else { return nil }
            return resolveFile(request, baseURL: baseURL).map(ResolvedTrack.file)
        case .mediaLibrary:
            return resolveMedia(request).map(ResolvedTrack.media)
        }
    }

    // MARK: - File source (the original 4-step fallback)

    private func resolveFile(_ request: TrackAddRequest, baseURL: URL) -> URL? {
        guard let relativePath = request.relativePath else { return nil }
        let relative = relativePath as NSString
        let relativeDir = relative.deletingLastPathComponent
        let stem = (relative.lastPathComponent as NSString).deletingPathExtension

        // 1. Exact relative path.
        let exact = baseURL.appending(path: relativePath)
        if isAudioFile(exact) { return exact }

        // 2. Same folder + stem, any other supported audio extension.
        if !stem.isEmpty {
            let dir = relativeDir.isEmpty ? baseURL : baseURL.appending(path: relativeDir)
            for ext in AudioFileTypes.audioExtensions {
                let candidate = dir.appending(path: "\(stem).\(ext)")
                if isAudioFile(candidate) { return candidate }
            }
        }

        // 3. Metadata match (title + artist, year disambiguates).
        if let match = resolveByMetadata(request, baseURL: baseURL) { return match }

        // 4. Recursive filename-stem search (any supported audio extension).
        return resolveByRecursiveStem(stem, under: baseURL)
    }

    // MARK: - Steps

    private func resolveByMetadata(_ request: TrackAddRequest, baseURL: URL) -> URL? {
        guard let container, let title = request.title, !title.isEmpty else { return nil }
        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<TrackMetadata>()) else { return nil }

        var candidates = rows.filter { row in
            equal(row.title, title) && (request.artist == nil || equal(row.artist, request.artist))
        }
        // Year only narrows when several title+artist matches remain.
        if candidates.count > 1, let year = request.year {
            let narrowed = candidates.filter { $0.year == year }
            if !narrowed.isEmpty { candidates = narrowed }
        }

        for row in candidates {
            // Cache keys are base-relative paths; skip the "filename|size" fallback
            // keys used for out-of-base files (not a usable relative path here).
            guard !row.trackKey.contains("|") else { continue }
            let url = baseURL.appending(path: row.trackKey)
            if isAudioFile(url) { return url }
        }
        return nil
    }

    private func resolveByRecursiveStem(_ stem: String, under root: URL) -> URL? {
        guard !stem.isEmpty,
              let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        let target = stem.lowercased()
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular, AudioFileTypes.isAudio(url) else { continue }
            if url.deletingPathExtension().lastPathComponent.lowercased() == target { return url }
        }
        return nil
    }

    // MARK: - Media source (the receiver's own Music library)

    /// Match the request against the receiver's library by metadata — persistentID
    /// is per-device, so title/artist (then album, year, nearest duration) is the
    /// only cross-device-correct key. Each filter is applied only while it still
    /// leaves more than one candidate, so a missing/wrong field never zeroes a good
    /// match. Returns only a locally-playable item (non-nil assetURL); otherwise
    /// the request is counted as failed rather than enqueued-then-unplayable.
    private func resolveMedia(_ request: TrackAddRequest) -> MPMediaItem? {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              let title = request.title, !title.isEmpty else { return nil }

        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: title,
                                                          forProperty: MPMediaItemPropertyTitle,
                                                          comparisonType: .equalTo))
        if let artist = request.artist, !artist.isEmpty {
            query.addFilterPredicate(MPMediaPropertyPredicate(value: artist,
                                                              forProperty: MPMediaItemPropertyArtist,
                                                              comparisonType: .equalTo))
        }
        guard var items = query.items, !items.isEmpty else { return nil }

        if items.count > 1, let album = request.album, !album.isEmpty {
            let byAlbum = items.filter { equal($0.albumTitle, album) }
            if !byAlbum.isEmpty { items = byAlbum }
        }
        if items.count > 1, let year = request.year {
            let byYear = items.filter { releaseYear(of: $0) == year }
            if !byYear.isEmpty { items = byYear }
        }
        if items.count > 1, let hint = request.durationHint {
            items.sort { abs($0.playbackDuration - hint) < abs($1.playbackDuration - hint) }
        }
        return items.first { $0.assetURL != nil }
    }

    private func releaseYear(of item: MPMediaItem) -> Int? {
        item.releaseDate.map { Calendar.current.component(.year, from: $0) }
    }

    // MARK: - Helpers

    private func isAudioFile(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) && AudioFileTypes.isAudio(url)
    }

    private func equal(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
