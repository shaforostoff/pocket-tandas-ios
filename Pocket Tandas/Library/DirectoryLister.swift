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
//  Metadata-based sorts (date/genre/bpm/artist) read the cached snapshot and
//  apply a fixed chain of secondary criteria, with filename as the final
//  tiebreak (see `metadataOrder`, which the Music-library browser shares).
//

import Foundation

enum DirectoryLister {
    /// Disk listing only (subfolders, audio, playlists), unsorted/unfiltered.
    /// `baseURL` is what each audio entry's cache key is derived against.
    static func rawEntries(in folder: URL, baseURL: URL?) -> [LibraryEntry] {
        let fm = FileManager.default
        // The modification date and size are what the metadata scan checks each
        // track's cache entry against, right after this listing and in the same
        // run-loop turn — which is as long as NSURL keeps a prefetched value. One
        // bulk read here instead of a stat per file there: 982 files listed then
        // stat'ed one by one took 55-72 ms, prefetched 22 ms. The size is also what
        // keys a track outside the base folder (see StableTrackID).
        guard let urls = try? fm.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: [.isDirectoryKey,
                                                                                  .contentModificationDateKey,
                                                                                  .fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        var entries: [LibraryEntry] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                entries.append(LibraryEntry(url: url, kind: .folder, baseURL: baseURL))
            } else if AudioFileTypes.isPlaylist(url) {
                entries.append(LibraryEntry(url: url, kind: .playlist, baseURL: baseURL))
            } else if AudioFileTypes.isAudio(url) {
                entries.append(LibraryEntry(url: url, kind: .audio, baseURL: baseURL))
            }
        }
        return entries
    }

    /// Pure filter + sort over already-listed entries.
    static func arrange(_ entries: [LibraryEntry],
                        filter: String,
                        sort: SortOption,
                        direction: SortDirection,
                        metadata: (LibraryEntry) -> TrackMetadataSnapshot?) -> [LibraryEntry] {
        var entries = entries

        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            entries = entries.filter { matches(needle, name: $0.name, snapshot: metadata($0)) }
        }

        let folders = entries
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let files = entries.filter { !$0.isFolder }
        var sortedFiles = sortFiles(files, sort: sort, metadata: metadata)
        if direction == .descending { sortedFiles.reverse() }

        return folders + sortedFiles
    }

    /// Sort the file entries by the chosen option. Metadata sorts use decorate–
    /// sort–undecorate: each file's snapshot is looked up ONCE up front, so the
    /// lookup runs n times rather than on every one of the O(n log n) comparisons
    /// — that per-comparison lookup (which probed the dict twice each compare, and
    /// once recomputed the StableTrackID key too) is what made date/BPM/artist sorts
    /// slow on large folders versus filename. The name and key need no decoration:
    /// the entry carries both (see LibraryEntry).
    private static func sortFiles(_ files: [LibraryEntry],
                                  sort: SortOption,
                                  metadata: (LibraryEntry) -> TrackMetadataSnapshot?) -> [LibraryEntry] {
        switch sort {
        case .listed:
            return files   // given order (e.g. a playlist's own order)
        case .filename:
            return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateYear, .genre, .bpm, .artist:
            return files
                .map { (entry: $0, snapshot: metadata($0)) }
                .sorted { metadataOrder($0.entry.name, $0.snapshot, $1.entry.name, $1.snapshot, by: sort) }
                .map(\.entry)
        }
    }

    // MARK: - Shared with the Music-library browser

    /// Whether a row matches the filter: its name and, when scanned, the track's
    /// title/artist/genre. `localizedStandardContains` folds case *and* diacritics
    /// (so "anibal" finds "Aníbal"), matching the locale-aware sort used elsewhere.
    static func matches(_ needle: String, name: String, snapshot: TrackMetadataSnapshot?) -> Bool {
        if name.localizedStandardContains(needle) { return true }
        guard let m = snapshot else { return false }
        return [m.title, m.artist, m.genre]
            .compactMap { $0 }
            .contains { $0.localizedStandardContains(needle) }
    }

    /// Multi-level ascending order for metadata sorts. Each option has a priority
    /// chain of criteria; when one ties, the next decides, and the row's name — a
    /// filename here, a title in the Music browser — is always the final tiebreak.
    /// Short-circuits, so a deeper field is only compared on a tie.
    static func metadataOrder(_ aName: String, _ a: TrackMetadataSnapshot?,
                              _ bName: String, _ b: TrackMetadataSnapshot?,
                              by sort: SortOption) -> Bool {
        var c: ComparisonResult
        switch sort {
        case .dateYear:
            c = compareYear(a, b)
        case .genre:
            c = compareGenre(a, b)
            if c == .orderedSame { c = compareYear(a, b) }
        case .artist:
            c = compareArtist(a, b)
            if c == .orderedSame { c = compareGenre(a, b) }
            if c == .orderedSame { c = compareYear(a, b) }
        case .bpm:
            c = compareBPM(a, b)
            if c == .orderedSame { c = compareArtist(a, b) }
            if c == .orderedSame { c = compareYear(a, b) }
        case .listed, .filename:
            c = .orderedSame   // name order only
        }
        if c == .orderedSame { c = aName.localizedStandardCompare(bName) }
        return c == .orderedAscending
    }

    // Per-field comparators for the chains above (nil sorts first: Int.min / "").
    private typealias Snapshot = TrackMetadataSnapshot?
    private static func compareYear(_ a: Snapshot, _ b: Snapshot) -> ComparisonResult {
        let x = a?.year ?? Int.min, y = b?.year ?? Int.min
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
    private static func compareBPM(_ a: Snapshot, _ b: Snapshot) -> ComparisonResult {
        let x = a?.bpm ?? Int.min, y = b?.bpm ?? Int.min
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
    private static func compareGenre(_ a: Snapshot, _ b: Snapshot) -> ComparisonResult {
        (a?.genre ?? "").localizedStandardCompare(b?.genre ?? "")
    }
    private static func compareArtist(_ a: Snapshot, _ b: Snapshot) -> ComparisonResult {
        (a?.artist ?? "").localizedStandardCompare(b?.artist ?? "")
    }
}
