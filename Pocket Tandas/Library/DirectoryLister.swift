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

        var files = entries.filter { !$0.isFolder }
        // `.listed` keeps the entries' given order (e.g. a playlist's own order);
        // every other option sorts by the chosen key.
        if sort != .listed {
            files.sort { ascendingOrder($0, $1, sort: sort, metadata: metadata) }
        }
        if direction == .descending { files.reverse() }

        return folders + files
    }

    private static func ascendingOrder(_ a: LibraryEntry,
                                       _ b: LibraryEntry,
                                       sort: SortOption,
                                       metadata: (URL) -> TrackMetadataSnapshot?) -> Bool {
        func byName() -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        switch sort {
        case .listed, .filename:   // `.listed` is handled before this point
            return byName()
        case .dateYear:
            let ya = metadata(a.url)?.year ?? Int.min
            let yb = metadata(b.url)?.year ?? Int.min
            return ya == yb ? byName() : ya < yb
        case .bpm:
            let ba = metadata(a.url)?.bpm ?? Int.min
            let bb = metadata(b.url)?.bpm ?? Int.min
            return ba == bb ? byName() : ba < bb
        case .artist:
            let aa = metadata(a.url)?.artist ?? ""
            let ab = metadata(b.url)?.artist ?? ""
            let c = aa.localizedStandardCompare(ab)
            return c == .orderedSame ? byName() : c == .orderedAscending
        }
    }
}
