// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlayQueue.swift
//  Pocket Tandas
//
//  The live play queue. Edited by the UI during playback; read by the engine at
//  the transition moment via `item(after:)` — never cached — so an edit made
//  seconds before the current track ends is honoured.
//

import Foundation
import Observation

@Observable
final class PlayQueue {
    private(set) var items: [QueueItem] = []

    /// Current base folder, used to store queue entries as relocatable,
    /// base-relative references. Kept in sync by the app.
    @ObservationIgnored var baseURL: URL?
    @ObservationIgnored private var persistenceEnabled = false
    @ObservationIgnored private let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
    }

    // MARK: - Editing

    func append(_ item: QueueItem) {
        items.append(item)
        persist()
    }

    /// Append many at once (e.g. a whole playlist) with a single save.
    func append(contentsOf newItems: [QueueItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        persist()
    }

    func insert(_ item: QueueItem, after id: QueueItem.ID) {
        if let idx = index(of: id) {
            items.insert(item, at: idx + 1)
        } else {
            items.append(item)
        }
        persist()
    }

    func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
    }

    /// Empty the queue. Playback (which holds its own current item and scheduled
    /// file) is unaffected and continues until the running track ends, after
    /// which `item(after:)` returns nil and the engine stops.
    func removeAll() {
        items.removeAll()
        persist()
    }

    /// Reorder. If `pinnedID` is given and the dragged item IS the pinned
    /// (currently playing) track, the move is rejected — the playing track can't
    /// be relocated. Moving *other* items (including across the pinned one) is
    /// allowed. Enforcing the pin here, by identity, rather than via the view's
    /// `.moveDisabled`, keeps the `.onMove` offsets in one consistent index space
    /// so `Array.move` can't reorder the wrong element.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, pinnedID: QueueItem.ID? = nil) {
        if let pinnedID, let pinnedIndex = index(of: pinnedID), source.contains(pinnedIndex) {
            return
        }
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Queries

    func index(of id: QueueItem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    func item(withID id: QueueItem.ID?) -> QueueItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// The live "what plays next" read. Returns the item immediately after `id`
    /// in the current array, or nil if `id` is last / not found.
    func item(after id: QueueItem.ID) -> QueueItem? {
        guard let idx = index(of: id), idx + 1 < items.count else { return nil }
        return items[idx + 1]
    }

    /// Compact dump for diagnostic logging: "0:foo.mp3#a1b2 | 1:bar.mp3#c3d4".
    var debugOrder: String {
        items.enumerated()
            .map { "\($0.offset):\($0.element.filename)#\($0.element.id.uuidString.prefix(4))" }
            .joined(separator: " | ")
    }

    // MARK: - Persistence

    private struct StoredItem: Codable {
        var relativePath: String?
        var absolutePath: String?
    }

    private static let defaultStoreURL: URL = {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        return dir.appendingPathComponent("play-queue.json")
    }()

    /// Rebuild the queue from disk, resolving each entry against the current base
    /// folder so it survives the base resolving to a new absolute path; entries
    /// whose file is gone are dropped. Enables saving for subsequent edits, so
    /// call once at launch after the base folder has been restored.
    func restore(baseURL: URL?) {
        self.baseURL = baseURL
        persistenceEnabled = true
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([StoredItem].self, from: data) else { return }
        let fm = FileManager.default
        items = stored.compactMap { entry in
            let url: URL
            if let rel = entry.relativePath, let base = baseURL {
                url = base.appending(path: rel)
            } else if let abs = entry.absolutePath {
                url = URL(fileURLWithPath: abs)
            } else {
                return nil
            }
            guard fm.fileExists(atPath: url.path) else { return nil }
            return QueueItem(url: url, trackKey: StableTrackID.key(for: url, baseURL: baseURL))
        }
    }

    /// Write the queue as relocatable references (base-relative where possible).
    private func persist() {
        guard persistenceEnabled else { return }   // off until the app calls restore()
        let stored = items.map { item -> StoredItem in
            if let rel = StableTrackID.relativePath(for: item.url, baseURL: baseURL) {
                return StoredItem(relativePath: rel, absolutePath: nil)
            }
            return StoredItem(relativePath: nil, absolutePath: item.url.path)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
