// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataService.swift
//  Pocket Tandas
//
//  Scans audio files for metadata and caches the results. Strategy:
//   - An in-memory `snapshots` dict (observed by the UI) drives row display
//     without relying on SwiftData cross-context @Query propagation. A folder
//     scan publishes all of its results in one batch (see `scanFolder`) so rows
//     fill in and sort a single time, not one track at a time.
//   - SwiftData (TrackMetadata) is the durable store: hydrated into memory lazily
//     per folder (not all at launch), written as scans complete, keyed by
//     StableTrackID.
//
//  Plain @Observable (see observable-not-mainactor). All cache mutation happens
//  on the main actor; extraction runs concurrently off-main in a bounded group.
//

import Foundation
import SwiftData
import Observation

@Observable
final class MetadataService {
    /// trackKey -> snapshot (display fields plus source mod-date/size used for
    /// staleness). UI reads this; updates are observed.
    private(set) var snapshots: [String: TrackMetadataSnapshot] = [:]

    /// True while the most recent folder scan still has tracks outstanding. The
    /// browser reads it to defer metadata-based sorting until every row is known.
    private(set) var isScanningFolder = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var folderScanTask: Task<Void, Never>?
    @ObservationIgnored private var folderScanGeneration = 0
    @ObservationIgnored private let maxConcurrent = 4

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Lookup (UI)

    func snapshot(for url: URL, baseURL: URL?) -> TrackMetadataSnapshot? {
        snapshots[StableTrackID.key(for: url, baseURL: baseURL)]
    }

    func snapshot(forKey key: String) -> TrackMetadataSnapshot? {
        snapshots[key]
    }

    // MARK: - Seeding (no file to scan)

    /// Publish a snapshot directly, bypassing the file scan — for Music-library
    /// items, whose metadata comes from the MPMediaItem, not a file's tags. Kept
    /// in memory only: these `medialib:` keys are intentionally NOT written to the
    /// durable TrackMetadata store (which is file-oriented and feeds the remote
    /// resolver's metadata match).
    @MainActor
    func inject(_ snapshot: TrackMetadataSnapshot, forKey key: String) {
        snapshots[key] = snapshot
    }

    /// Seed display snapshots for the media-library items in `items` from their
    /// carried metadata. File items are ignored (they scan from disk).
    @MainActor
    func seedMedia(_ items: [QueueItem]) {
        for item in items {
            guard item.isMediaLibrary, let snapshot = item.mediaSnapshot else { continue }
            snapshots[item.trackKey] = snapshot
        }
    }

    // MARK: - Scanning

    /// Scan a folder's audio files, skipping cache hits. Cancels the previous
    /// folder scan (so leaving a folder stops its in-flight work). Holds
    /// `isScanningFolder` true until the whole folder is done, and publishes the
    /// results as one batch — never one track at a time.
    @MainActor
    func scanFolder(urls: [URL], baseURL: URL?) {
        folderScanTask?.cancel()
        let pending = urls.isEmpty ? [] : pendingItems(urls: urls, baseURL: baseURL)
        guard !pending.isEmpty else {
            // Nothing to scan for this folder (empty or fully cached).
            isScanningFolder = false
            return
        }
        isScanningFolder = true
        folderScanGeneration += 1
        let generation = folderScanGeneration
        folderScanTask = Task { @MainActor in
            await self.performScan(pending)
            // Only the newest scan owns the flag: a superseded (cancelled) scan
            // must not clear it out from under its replacement.
            if generation == self.folderScanGeneration {
                self.isScanningFolder = false
            }
        }
    }

    /// Scan specific URLs (e.g. tracks just added to the queue, or a playlist's
    /// tracks) without disturbing an in-flight folder scan or its scanning flag.
    @MainActor
    func scan(urls: [URL], baseURL: URL?) {
        guard !urls.isEmpty else { return }
        let pending = pendingItems(urls: urls, baseURL: baseURL)
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            await self.performScan(pending)
        }
    }

    /// Cache misses / stale entries among `urls`, in input order. Hydrates the
    /// in-memory cache for these keys first (lazy, per-folder), so a hit here
    /// reflects the durable store even though it was never bulk-loaded at launch.
    @MainActor
    private func pendingItems(urls: [URL], baseURL: URL?) -> [(url: URL, key: String, modDate: Date, size: Int)] {
        // Read each file's key + current identity once.
        let items = urls.map { url -> (url: URL, key: String, modDate: Date, size: Int) in
            let key = StableTrackID.key(for: url, baseURL: baseURL)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, key, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }

        hydrate(keys: items.map(\.key))

        // Pending = no in-memory snapshot whose mod-date AND size still match.
        return items.filter { item in
            guard let cached = snapshots[item.key],
                  cached.sourceModDate == item.modDate, cached.fileSize == item.size else { return true }
            return false
        }
    }

    /// Pull cached snapshots for `keys` not yet in memory from the durable store.
    /// This is the lazy, per-folder replacement for bulk-loading the whole cache
    /// at launch: memory holds only what the user has actually browsed.
    @MainActor
    private func hydrate(keys: [String]) {
        let missing = keys.filter { snapshots[$0] == nil }
        guard !missing.isEmpty else { return }
        for (key, m) in existingRows(forKeys: missing, context: container.mainContext) {
            snapshots[key] = TrackMetadataSnapshot(title: m.title, artist: m.artist, genre: m.genre,
                                                   dateText: m.dateText, year: m.year, bpm: m.bpm,
                                                   trackGainDB: m.trackGainDB,
                                                   sourceModDate: m.sourceModDate, fileSize: m.fileSize ?? 0)
        }
    }

    /// Existing rows for `keys` as a key -> row map, fetched in chunks to stay
    /// under SQLite's bound-variable limit on the `IN (…)` query.
    @MainActor
    private func existingRows(forKeys keys: [String], context: ModelContext) -> [String: TrackMetadata] {
        var rows: [String: TrackMetadata] = [:]
        let chunkSize = 400
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start..<min(start + chunkSize, keys.count)])
            let descriptor = FetchDescriptor<TrackMetadata>(predicate: #Predicate { chunk.contains($0.trackKey) })
            for row in (try? context.fetch(descriptor)) ?? [] { rows[row.trackKey] = row }
            start += chunkSize
        }
        return rows
    }

    @MainActor
    private func performScan(_ pending: [(url: URL, key: String, modDate: Date, size: Int)]) async {
        guard !pending.isEmpty else { return }
        let context = container.mainContext

        // Extract off-main in a bounded group, collecting every result. We do NOT
        // touch the observed `snapshots` here: publishing one track at a time is
        // exactly the per-row pop-in and mid-scan reordering we want to avoid.
        var results: [(key: String, modDate: Date, size: Int, extracted: ExtractedMetadata)] = []
        await withTaskGroup(of: (String, Date, Int, ExtractedMetadata).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let next = iterator.next() else { return }
                group.addTask { (next.key, next.modDate, next.size, await MetadataExtractor.extract(url: next.url)) }
            }
            for _ in 0..<maxConcurrent { addNext() }

            for await (key, modDate, size, extracted) in group {
                if Task.isCancelled { break }
                results.append((key: key, modDate: modDate, size: size, extracted: extracted))
                addNext()
            }
        }

        // Folder left mid-scan: drop the partial batch rather than publish a
        // folder the user has already navigated away from.
        guard !Task.isCancelled else { return }

        // Dedup by key (fallback "filename|size" keys can repeat across folders),
        // then fetch all existing rows in one batched query instead of one per
        // track. Publish in a single synchronous pass so the UI updates once.
        var seen = Set<String>()
        let unique = results.filter { seen.insert($0.key).inserted }
        let existing = existingRows(forKeys: unique.map(\.key), context: context)
        for r in unique {
            apply(key: r.key, modDate: r.modDate, size: r.size, extracted: r.extracted,
                  existing: existing[r.key], context: context)
        }
        try? context.save()
    }

    @MainActor
    private func apply(key: String, modDate: Date, size: Int, extracted: ExtractedMetadata,
                       existing: TrackMetadata?, context: ModelContext) {
        snapshots[key] = extracted.snapshot(sourceModDate: modDate, fileSize: size)

        if let existing {
            existing.title = extracted.title
            existing.artist = extracted.artist
            existing.genre = extracted.genre
            existing.dateText = extracted.dateText
            existing.year = extracted.year
            existing.bpm = extracted.bpm
            existing.trackGainDB = extracted.trackGainDB
            existing.sourceModDate = modDate
            existing.fileSize = size
            existing.lastScanned = .now
        } else {
            context.insert(TrackMetadata(trackKey: key, title: extracted.title, artist: extracted.artist,
                                         genre: extracted.genre, dateText: extracted.dateText,
                                         year: extracted.year, bpm: extracted.bpm,
                                         trackGainDB: extracted.trackGainDB,
                                         sourceModDate: modDate, fileSize: size, lastScanned: .now))
        }
    }
}
