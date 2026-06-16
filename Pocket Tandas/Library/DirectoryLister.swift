// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  DirectoryLister.swift
//  Pocket Tandas
//
//  Splits the work so the browser lists a folder from disk only once per folder
//  (`rawEntries`), then filters + sorts the cached result purely (`arrange`) —
//  which can re-run cheaply on every render as metadata scans land.
//
//  Folders are always grouped first; files are sorted by the chosen option.
//  Metadata-based sorts (date/bpm/artist) use the cache via the `metadata`
//  lookup, falling back to filename when unavailable.
//

import Foundation

enum DirectoryLister {
    /// Disk listing only (subfolders, audio, playlists), unsorted/unfiltered.
    static func rawEntries(in folder: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [LibraryEntry] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                entries.append(LibraryEntry(url: url, kind: .folder))
            } else if AudioFileTypes.isPlaylist(url) {
                entries.append(LibraryEntry(url: url, kind: .playlist))
            } else if AudioFileTypes.isAudio(url) {
                entries.append(LibraryEntry(url: url, kind: .audio))
            }
        }
        return entries
    }

    /// Pure filter + sort over already-listed entries.
    static func arrange(_ entries: [LibraryEntry],
                        filter: String,
                        sort: SortOption,
                        direction: SortDirection,
                        metadata: (URL) -> TrackMetadataSnapshot?) -> [LibraryEntry] {
        var entries = entries

        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            // Match the filename and, when scanned, the track's title/artist/genre.
            // `localizedStandardContains` folds case *and* diacritics (so "anibal"
            // finds "Aníbal"), matching the locale-aware sort used elsewhere.
            entries = entries.filter { entry in
                if entry.name.localizedStandardContains(needle) { return true }
                guard let m = metadata(entry.url) else { return false }
                return [m.title, m.artist, m.genre]
                    .compactMap { $0 }
                    .contains { $0.localizedStandardContains(needle) }
            }
        }

        let folders = entries
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let files = entries.filter { !$0.isFolder }
        var sortedFiles = sortFiles(files, sort: sort, metadata: metadata)
        if direction == .descending { sortedFiles.reverse() }

        return folders + sortedFiles
    }

    private typealias Decorated = (entry: LibraryEntry, name: String, snapshot: TrackMetadataSnapshot?)

    /// Sort the file entries by the chosen option. Metadata sorts use decorate–
    /// sort–undecorate: each file's key (name + cached snapshot) is computed ONCE
    /// up front, so the metadata lookup runs n times rather than on every one of
    /// the O(n log n) comparisons — that per-comparison lookup (which recomputes
    /// the StableTrackID key and probes the dict twice each compare) is what made
    /// date/BPM/artist sorts slow on large folders versus filename.
    private static func sortFiles(_ files: [LibraryEntry],
                                  sort: SortOption,
                                  metadata: (URL) -> TrackMetadataSnapshot?) -> [LibraryEntry] {
        switch sort {
        case .listed:
            return files   // given order (e.g. a playlist's own order)
        case .filename:
            return files
                .map { (entry: $0, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(\.entry)
        case .dateYear, .genre, .bpm, .artist:
            return files
                .map { (entry: $0, name: $0.name, snapshot: metadata($0.url)) }
                .sorted { ascendingOrder($0, $1, sort: sort) }
                .map(\.entry)
        }
    }

    private static func ascendingOrder(_ a: Decorated, _ b: Decorated, sort: SortOption) -> Bool {
        func byName() -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        switch sort {
        case .dateYear:
            let ya = a.snapshot?.year ?? Int.min
            let yb = b.snapshot?.year ?? Int.min
            return ya == yb ? byName() : ya < yb
        case .genre:
            let ga = a.snapshot?.genre ?? ""
            let gb = b.snapshot?.genre ?? ""
            let c = ga.localizedStandardCompare(gb)
            return c == .orderedSame ? byName() : c == .orderedAscending
        case .bpm:
            let ba = a.snapshot?.bpm ?? Int.min
            let bb = b.snapshot?.bpm ?? Int.min
            return ba == bb ? byName() : ba < bb
        case .artist:
            let aa = a.snapshot?.artist ?? ""
            let ab = b.snapshot?.artist ?? ""
            let c = aa.localizedStandardCompare(ab)
            return c == .orderedSame ? byName() : c == .orderedAscending
        case .listed, .filename:
            return byName()   // not reached (handled in sortFiles)
        }
    }
}
