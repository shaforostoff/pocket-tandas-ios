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

    // MARK: - Editing

    func append(_ item: QueueItem) {
        items.append(item)
    }

    func insert(_ item: QueueItem, after id: QueueItem.ID) {
        if let idx = index(of: id) {
            items.insert(item, at: idx + 1)
        } else {
            items.append(item)
        }
    }

    func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id }
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
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
}
