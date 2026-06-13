// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataService.swift
//  Pocket Tandas
//
//  Scans audio files for metadata and caches the results. Strategy:
//   - An in-memory `snapshots` dict (observed by the UI) gives reliable, instant
//     row updates — no reliance on SwiftData cross-context @Query propagation.
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
    /// trackKey -> snapshot. UI reads this; updates are observed.
    private(set) var snapshots: [String: TrackMetadataSnapshot] = [:]

    @ObservationIgnored private var modDates: [String: Date] = [:]
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var folderScanTask: Task<Void, Never>?
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
    /// folder scan (so leaving a folder stops its in-flight work).
    func scanFolder(urls: [URL], baseURL: URL?) {
        guard !urls.isEmpty else { return }
        folderScanTask?.cancel()
        folderScanTask = Task { @MainActor in
            await self.performScan(urls: urls, baseURL: baseURL)
        }
    }

    /// Scan specific URLs (e.g. tracks just added to the queue, or a playlist's
    /// tracks) without disturbing an in-flight folder scan.
    func scan(urls: [URL], baseURL: URL?) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await self.performScan(urls: urls, baseURL: baseURL)
        }
    }

    @MainActor
    private func loadCache() {
        let context = container.mainContext
        guard let all = try? context.fetch(FetchDescriptor<TrackMetadata>()) else { return }
        for m in all {
            snapshots[m.trackKey] = TrackMetadataSnapshot(title: m.title, artist: m.artist,
                                                          genre: m.genre, dateText: m.dateText,
                                                          year: m.year, bpm: m.bpm)
            modDates[m.trackKey] = m.sourceModDate
        }
    }

    @MainActor
    private func performScan(urls: [URL], baseURL: URL?) async {
        // Determine cache misses / stale entries up front.
        var pending: [(url: URL, key: String, modDate: Date)] = []
        for url in urls {
            let key = StableTrackID.key(for: url, baseURL: baseURL)
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let known = modDates[key], known == modDate { continue }   // cache hit
            pending.append((url, key, modDate))
        }
        guard !pending.isEmpty else { return }

        let context = container.mainContext

        await withTaskGroup(of: (String, Date, ExtractedMetadata).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let next = iterator.next() else { return }
                group.addTask { (next.key, next.modDate, await MetadataExtractor.extract(url: next.url)) }
            }
            for _ in 0..<maxConcurrent { addNext() }

            for await (key, modDate, extracted) in group {
                if Task.isCancelled { break }
                apply(key: key, modDate: modDate, extracted: extracted, context: context)
                addNext()
            }
        }
        try? context.save()
    }

    @MainActor
    private func apply(key: String, modDate: Date, extracted: ExtractedMetadata, context: ModelContext) {
        snapshots[key] = extracted.snapshot
        modDates[key] = modDate

        let descriptor = FetchDescriptor<TrackMetadata>(predicate: #Predicate { $0.trackKey == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = extracted.title
            existing.artist = extracted.artist
            existing.genre = extracted.genre
            existing.dateText = extracted.dateText
            existing.year = extracted.year
            existing.bpm = extracted.bpm
            existing.sourceModDate = modDate
            existing.lastScanned = .now
        } else {
            context.insert(TrackMetadata(trackKey: key, title: extracted.title, artist: extracted.artist,
                                         genre: extracted.genre, dateText: extracted.dateText,
                                         year: extracted.year, bpm: extracted.bpm,
                                         sourceModDate: modDate, lastScanned: .now))
        }
    }
}
