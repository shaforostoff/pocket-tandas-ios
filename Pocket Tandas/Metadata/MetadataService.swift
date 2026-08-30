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
//   - SwiftData (TrackMetadata) is the durable store: loaded into memory at
//     launch, written as scans complete, keyed by StableTrackID.
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
        Task { @MainActor in self.loadCache() }
    }

    // MARK: - Lookup (UI)

    func snapshot(for url: URL, baseURL: URL?) -> TrackMetadataSnapshot? {
        snapshots[StableTrackID.key(for: url, baseURL: baseURL)]
    }

    func snapshot(forKey key: String) -> TrackMetadataSnapshot? {
        snapshots[key]
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

    /// Cache misses / stale entries among `urls`, in input order.
    @MainActor
    private func pendingItems(urls: [URL], baseURL: URL?) -> [(url: URL, key: String, modDate: Date, size: Int)] {
        var pending: [(url: URL, key: String, modDate: Date, size: Int)] = []
        for url in urls {
            let key = StableTrackID.key(for: url, baseURL: baseURL)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modDate = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            // Cache hit only when both the mod-date and the size still match.
            if let cached = snapshots[key], cached.sourceModDate == modDate, cached.fileSize == size { continue }
            pending.append((url, key, modDate, size))
        }
        return pending
    }

    @MainActor
    private func loadCache() {
        let context = container.mainContext

        // The key scheme changed (path-only for in-base files), so any pre-existing
        // rows are keyed differently and unreachable. Purge them once — keeping them
        // would only waste memory and disk — and let the next scans repopulate.
        let schemaKey = "metadataCacheKeySchema"
        let schemaVersion = 2
        if UserDefaults.standard.integer(forKey: schemaKey) < schemaVersion {
            try? context.delete(model: TrackMetadata.self)
            try? context.save()
            UserDefaults.standard.set(schemaVersion, forKey: schemaKey)
            return
        }

        guard let all = try? context.fetch(FetchDescriptor<TrackMetadata>()) else { return }
        for m in all {
            snapshots[m.trackKey] = TrackMetadataSnapshot(title: m.title, artist: m.artist,
                                                          genre: m.genre, dateText: m.dateText,
                                                          year: m.year, bpm: m.bpm,
                                                          trackGainDB: m.trackGainDB,
                                                          sourceModDate: m.sourceModDate,
                                                          fileSize: m.fileSize ?? 0)
        }
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

        // Publish everything in a single synchronous pass so the UI observes one
        // update: rows fill in and (re)sort exactly once, when all metadata is in.
        for r in results {
            apply(key: r.key, modDate: r.modDate, size: r.size, extracted: r.extracted, context: context)
        }
        try? context.save()
    }

    @MainActor
    private func apply(key: String, modDate: Date, size: Int, extracted: ExtractedMetadata, context: ModelContext) {
        snapshots[key] = extracted.snapshot(sourceModDate: modDate, fileSize: size)

        let descriptor = FetchDescriptor<TrackMetadata>(predicate: #Predicate { $0.trackKey == key })
        if let existing = try? context.fetch(descriptor).first {
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
