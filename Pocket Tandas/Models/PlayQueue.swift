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
import MediaPlayer

@Observable
final class PlayQueue {
    private(set) var items: [QueueItem] = []

    /// The insert anchor, if any. While set, newly enqueued tracks are inserted
    /// immediately *above* this item instead of appended at the end; at most one
    /// exists at a time. Live DJ state, in-memory only (not persisted): it's a
    /// transient "insert upcoming tracks here" marker, and items are reassigned
    /// fresh ids on `restore`, so a stored id couldn't be rematched anyway.
    private(set) var anchorID: QueueItem.ID?

    /// Current base folder, used to store queue entries as relocatable,
    /// base-relative references. Kept in sync by the app.
    @ObservationIgnored var baseURL: URL?
    @ObservationIgnored private var persistenceEnabled = false
    @ObservationIgnored private let storeURL: URL

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL
    }

    // MARK: - Editing

    /// Add a track, honouring the insert anchor: when an anchor is set, insert
    /// immediately above it; otherwise append at the end.
    func enqueue(_ item: QueueItem) {
        if let anchorID, let idx = index(of: anchorID) {
            items.insert(item, at: idx)
        } else {
            items.append(item)
        }
        persist()
    }

    /// Add many at once (e.g. a whole playlist) with a single save. The block
    /// keeps its order and lands together — above the anchor when one is set,
    /// otherwise at the end.
    func enqueue(contentsOf newItems: [QueueItem]) {
        guard !newItems.isEmpty else { return }
        if let anchorID, let idx = index(of: anchorID) {
            items.insert(contentsOf: newItems, at: idx)
        } else {
            items.append(contentsOf: newItems)
        }
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
        pruneAnchor()
        persist()
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        pruneAnchor()
        persist()
    }

    /// Empty the queue. Playback (which holds its own current item and scheduled
    /// file) is unaffected and continues until the running track ends, after
    /// which `item(after:)` returns nil and the engine stops.
    func removeAll() {
        items.removeAll()
        pruneAnchor()
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

    // MARK: - Insert anchor

    /// Set the insert anchor (pass nil to clear). New tracks then insert above
    /// the anchored item until it is played, removed, or cleared.
    func setAnchor(_ id: QueueItem.ID?) {
        anchorID = id
    }

    /// Clear the anchor when its track starts playing. The engine calls this as
    /// each track becomes current, so playback reaching the anchor drops it.
    func clearAnchor(ifMatches id: QueueItem.ID) {
        if anchorID == id { anchorID = nil }
    }

    /// Drop a dangling anchor whose item has left the queue (after a removal). A
    /// move keeps the anchored item present, so the anchor survives a reorder.
    private func pruneAnchor() {
        if let anchorID, index(of: anchorID) == nil { self.anchorID = nil }
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
        // File items: a relocatable relative path, else an absolute path.
        var relativePath: String? = nil
        var absolutePath: String? = nil
        // Media-library items: the persistent id (stable on this device) plus the
        // cached display fields, so the row shows correctly at launch and the
        // snapshot can be re-seeded before re-resolution completes.
        var mediaPersistentID: UInt64? = nil
        var title: String? = nil
        var artist: String? = nil
        var genre: String? = nil
        var dateText: String? = nil
        var year: Int? = nil
        var bpm: Int? = nil
        var duration: TimeInterval? = nil
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
            if let pid = entry.mediaPersistentID {
                return Self.restoreMediaItem(entry, persistentID: pid)
            }
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

    /// Rebuild a media item from its stored persistent id. When the library is
    /// authorized, re-resolve the asset URL (persistent id is stable on this
    /// device) and drop the entry only if the track is genuinely gone. When access
    /// hasn't been granted yet (cold launch), keep a placeholder with a nil asset
    /// URL so the queue survives — it resolves on first play / once granted.
    private static func restoreMediaItem(_ entry: StoredItem, persistentID pid: UInt64) -> QueueItem? {
        let cached = TrackMetadataSnapshot(title: entry.title, artist: entry.artist, genre: entry.genre,
                                           dateText: entry.dateText, year: entry.year, bpm: entry.bpm,
                                           trackGainDB: nil)
        let title = entry.title ?? "Unknown"
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            let ref = MediaRef(persistentID: pid, assetURL: nil, displayTitle: title,
                               duration: entry.duration ?? 0)
            return QueueItem(media: ref, snapshot: cached)
        }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                          forProperty: MPMediaItemPropertyPersistentID))
        guard let mp = query.items?.first else { return nil }   // track removed from the library
        let ref = MediaRef(persistentID: pid, assetURL: mp.assetURL,
                           displayTitle: mp.title ?? title, duration: mp.playbackDuration)
        return QueueItem(media: ref, snapshot: cached)
    }

    /// Write the queue as relocatable references (base-relative where possible).
    private func persist() {
        guard persistenceEnabled else { return }   // off until the app calls restore()
        let stored = items.map { item -> StoredItem in
            switch item.source {
            case .file(let url):
                if let rel = StableTrackID.relativePath(for: url, baseURL: baseURL) {
                    return StoredItem(relativePath: rel)
                }
                return StoredItem(absolutePath: url.path)
            case .mediaLibrary(let ref):
                let snap = item.mediaSnapshot
                return StoredItem(mediaPersistentID: ref.persistentID,
                                  title: snap?.title, artist: snap?.artist, genre: snap?.genre,
                                  dateText: snap?.dateText, year: snap?.year, bpm: snap?.bpm,
                                  duration: ref.duration)
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
