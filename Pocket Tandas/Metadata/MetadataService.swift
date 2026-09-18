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
//   - Where the tags leave a gap — no BPM, or no genre — the track is handed to
//     TrackAnalysisQueue to be measured. That is a second, much slower pass over
//     the same tracks, cached in its own table (TrackAnalysis) and merged into the
//     same snapshots. Tags always win: see TrackMetadataSnapshot.
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

    /// Bumped once per batch that changes `snapshots`. A view that has to recompute
    /// something derived (the browser's filter + sort) watches this instead of the
    /// dictionary, so the change check is an Int comparison rather than an equality
    /// walk over the whole cache.
    private(set) var snapshotsVersion = 0

    /// True while the most recent folder scan still has tracks outstanding. The
    /// browser reads it to defer metadata-based sorting until every row is known.
    private(set) var isScanningFolder = false

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var folderScanTask: Task<Void, Never>?
    @ObservationIgnored private var folderScanGeneration = 0
    @ObservationIgnored private let maxConcurrent = 4

    /// Measures the tracks whose tags left a gap. Created lazily so the callback
    /// can close over a fully initialised `self`; only ever touched on the main
    /// actor, which is where every submission is made.
    @ObservationIgnored private lazy var analysis = TrackAnalysisQueue { [weak self] key, result in
        self?.recordAnalysis(key: key, result: result)
    }

    /// Measurements waiting to be published, and whether a hop is already booked to
    /// do it. One track lands every few seconds for as long as a folder takes, and
    /// every publish re-sorts the browser — so a run of them is collapsed into one
    /// batch and one SwiftData save, the same as a folder scan publishes once.
    @ObservationIgnored private var pendingAnalysis: [String: TrackAnalysisResult] = [:]
    @ObservationIgnored private var analysisFlushScheduled = false
    @ObservationIgnored private let analysisFlushDelay: Duration = .milliseconds(1500)

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

    /// Seed display snapshots for the media-library items in `items` from their
    /// carried metadata, bypassing the file scan — a Music-library item's metadata
    /// comes from the MPMediaItem, not from a file's tags. File items are ignored
    /// (they scan from disk).
    ///
    /// The tags are kept in memory only: these `medialib:` keys are intentionally
    /// NOT written to the durable TrackMetadata store, which is file-oriented and
    /// feeds the remote resolver's metadata match. Measurements are a different
    /// story — TrackAnalysis holds those for library items too, so a track is read
    /// once and not again next launch.
    @MainActor
    func seedMedia(_ items: [QueueItem]) {
        var changed = false
        var measurable: [(key: String, url: URL)] = []
        for item in items {
            guard item.isMediaLibrary, let snapshot = item.mediaSnapshot else { continue }
            publish(snapshot, forKey: item.trackKey)
            changed = true
            // No file to scan, but there is audio to measure — a library item's
            // queue row reads its BPM and genre from here like any other. Items
            // with no readable asset (DRM, not yet downloaded) have no url and
            // are simply skipped.
            if let url = item.url { measurable.append((key: item.trackKey, url: url)) }
        }
        if changed { snapshotsVersion += 1 }
        resolveAnalysis(for: measurable, as: .standing)
    }

    /// Publish a snapshot, carrying over any measurement already folded into the
    /// one it replaces. Every write to `snapshots` goes through here: re-scanning a
    /// file's tags says nothing about its audio, so it must not throw away what the
    /// analyser found — that would send the whole folder back through a decode.
    @MainActor
    private func publish(_ snapshot: TrackMetadataSnapshot, forKey key: String) {
        var merged = snapshot
        if let previous = snapshots[key] {
            merged.estimatedBPM = previous.estimatedBPM
            merged.estimatedGenre = previous.estimatedGenre
        }
        snapshots[key] = merged
    }

    // MARK: - Scanning

    /// Scan a folder's audio files, skipping cache hits. Cancels the previous
    /// folder scan (so leaving a folder stops its in-flight work). Holds
    /// `isScanningFolder` true until the whole folder is done, and publishes the
    /// results as one batch — never one track at a time.
    @MainActor
    func scanFolder(urls: [URL], baseURL: URL?) {
        folderScanTask?.cancel()
        analysis.cancelFolderWork()
        let pending = urls.isEmpty ? [] : pendingItems(urls: urls, baseURL: baseURL)
        guard !pending.isEmpty else {
            // Nothing to scan for this folder (empty or fully cached) — but a
            // cached tag scan says nothing about whether the audio was measured,
            // so that pass still has to be offered the folder.
            isScanningFolder = false
            resolveAnalysis(urls: urls, baseURL: baseURL, as: .folder)
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
                // After the tags, not beside them: which tracks have a gap worth
                // measuring is not known until they have been read.
                self.resolveAnalysis(urls: urls, baseURL: baseURL, as: .folder)
            }
        }
    }

    /// Scan specific URLs (e.g. tracks just added to the queue, or a playlist's
    /// tracks) without disturbing an in-flight folder scan or its scanning flag.
    @MainActor
    func scan(urls: [URL], baseURL: URL?) {
        guard !urls.isEmpty else { return }
        let pending = pendingItems(urls: urls, baseURL: baseURL)
        guard !pending.isEmpty else {
            // Tags already cached — the measuring pass still has to see them.
            resolveAnalysis(urls: urls, baseURL: baseURL, as: .standing)
            return
        }
        Task { @MainActor in
            await self.performScan(pending)
            self.resolveAnalysis(urls: urls, baseURL: baseURL, as: .standing)
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
        var changed = false
        for (key, m) in existingRows(forKeys: missing, context: container.mainContext) {
            publish(TrackMetadataSnapshot(title: m.title, artist: m.artist, taggedGenre: m.genre,
                                          dateText: m.dateText, year: m.year, taggedBPM: m.bpm,
                                          trackGainDB: m.trackGainDB,
                                          sourceModDate: m.sourceModDate, fileSize: m.fileSize ?? 0),
                    forKey: key)
            changed = true
        }
        if changed { snapshotsVersion += 1 }
    }

    /// Existing rows for `keys` as a key -> row map, fetched in chunks to stay
    /// under SQLite's bound-variable limit on the `IN (…)` query.
    @MainActor
    private func existingRows(forKeys keys: [String], context: ModelContext) -> [String: TrackMetadata] {
        var rows: [String: TrackMetadata] = [:]
        for chunk in Self.chunked(keys) {
            let descriptor = FetchDescriptor<TrackMetadata>(predicate: #Predicate { chunk.contains($0.trackKey) })
            for row in (try? context.fetch(descriptor)) ?? [] { rows[row.trackKey] = row }
        }
        return rows
    }

    /// The same, for the measurements. Two functions rather than one generic one
    /// because `#Predicate` has to name the model's own key path.
    @MainActor
    private func analysisRows(forKeys keys: [String], context: ModelContext) -> [String: TrackAnalysis] {
        var rows: [String: TrackAnalysis] = [:]
        for chunk in Self.chunked(keys) {
            let descriptor = FetchDescriptor<TrackAnalysis>(predicate: #Predicate { chunk.contains($0.trackKey) })
            for row in (try? context.fetch(descriptor)) ?? [] { rows[row.trackKey] = row }
        }
        return rows
    }

    /// Keys split small enough to stay under SQLite's bound-variable limit on the
    /// `IN (…)` query a chunk becomes.
    private static func chunked(_ keys: [String]) -> [[String]] {
        stride(from: 0, to: keys.count, by: 400).map {
            Array(keys[$0..<min($0 + 400, keys.count)])
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
        if !unique.isEmpty { snapshotsVersion += 1 }
        try? context.save()
    }

    @MainActor
    private func apply(key: String, modDate: Date, size: Int, extracted: ExtractedMetadata,
                       existing: TrackMetadata?, context: ModelContext) {
        publish(extracted.snapshot(sourceModDate: modDate, fileSize: size), forKey: key)

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

    // MARK: - Analysis

    /// Fold in what has already been measured for these tracks, and set the rest
    /// going.
    ///
    /// A track is measured only where its tags left a gap — no BPM, or no genre.
    /// Nothing has to be undone when a tag turns up later: the snapshot prefers it
    /// on its own, and the measurement simply stops being the one that shows.
    @MainActor
    private func resolveAnalysis(for items: [(key: String, url: URL)],
                                 as batch: TrackAnalysisQueue.Batch) {
        guard !items.isEmpty else { return }
        let measured = analysisRows(forKeys: items.map(\.key), context: container.mainContext)

        var changed = false
        var jobs: [TrackAnalysisQueue.Job] = []
        var seen = Set<String>()
        for item in items where seen.insert(item.key).inserted {
            guard var snapshot = snapshots[item.key] else { continue }
            if let row = measured[item.key] {
                // Already measured, in an earlier session or an earlier visit.
                let result = row.result
                guard snapshot.estimatedBPM != result.bpm || snapshot.estimatedGenre != result.genre
                else { continue }
                snapshot.estimatedBPM = result.bpm
                snapshot.estimatedGenre = result.genre
                snapshots[item.key] = snapshot
                changed = true
            } else if snapshot.taggedBPM == nil || (snapshot.taggedGenre ?? "").isEmpty {
                jobs.append(TrackAnalysisQueue.Job(key: item.key, url: item.url))
            }
        }
        if changed { snapshotsVersion += 1 }
        analysis.submit(jobs, as: batch)
    }

    /// The same for a listing, which is held as URLs.
    @MainActor
    private func resolveAnalysis(urls: [URL], baseURL: URL?, as batch: TrackAnalysisQueue.Batch) {
        resolveAnalysis(for: urls.map { (key: StableTrackID.key(for: $0, baseURL: baseURL), url: $0) },
                        as: batch)
    }

    /// One track measured. Buffered rather than published: see `pendingAnalysis`.
    @MainActor
    private func recordAnalysis(key: String, result: TrackAnalysisResult) {
        pendingAnalysis[key] = result
        guard !analysisFlushScheduled else { return }
        analysisFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: self.analysisFlushDelay)
            self.flushAnalysis()
        }
    }

    /// Write the buffered measurements and publish them as one batch.
    @MainActor
    private func flushAnalysis() {
        analysisFlushScheduled = false
        let batch = pendingAnalysis
        pendingAnalysis.removeAll()
        guard !batch.isEmpty else { return }

        let context = container.mainContext
        let existing = analysisRows(forKeys: Array(batch.keys), context: context)
        var changed = false
        for (key, result) in batch {
            if let row = existing[key] {
                row.update(with: result)
            } else {
                context.insert(TrackAnalysis(trackKey: key, result: result))
            }
            // Only where the track is still on screen; the measurement is stored
            // either way, and a folder the user has left has no snapshot to update.
            guard var snapshot = snapshots[key] else { continue }
            snapshot.estimatedBPM = result.bpm
            snapshot.estimatedGenre = result.genre
            snapshots[key] = snapshot
            changed = true
        }
        // Only when a snapshot actually moved. The version is what the browser
        // re-arranges on, and measurements keep landing for folders the user has
        // walked away from — bumping it for those re-sorted the folder they are
        // looking at, every flush, for nothing.
        if changed { snapshotsVersion += 1 }
        try? context.save()
    }
}
