// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteQueueSyncTests.swift
//  Pocket TandasTests
//
//  The receiver describes a queue change as an edit script against what the
//  sender last held (QueueEditScript); the sender replays it onto its mirror
//  (RemoteQueue). The row count is checked on arrival, but the order is not — so
//  a script that lands every row in the wrong place would show the DJ a wrong
//  queue without complaint. This drives both halves with random edits and checks
//  the mirror ends up exactly the receiver's queue.
//

import XCTest
@testable import Pocket_Tandas

final class RemoteQueueSyncTests: XCTestCase {
    func testDeltaRebuildsTheReceiversQueue() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let mirror = RemoteQueue(link: PeerLink(role: .sender))
            let receive = mirror.link.onReceive!

            // What the sender holds: a snapshot with every row's text.
            let old = Array(1..<(1 + Int.random(in: 0...12, using: &rng)))
            receive(.snapshot(RemoteSnapshot(items: old.map { row($0, "t\($0)") },
                                             anchor: nil, playback: RemotePlaybackState(), seq: 1)))

            // The receiver's edit: drop some rows, shuffle, add new ones, and
            // re-describe a few whose text changed.
            var new = old.filter { _ in Bool.random(using: &rng) }
            new += (100..<(100 + Int.random(in: 0...4, using: &rng)))
            new.shuffle(using: &rng)
            let renamed = Set(new.filter { $0 < 100 && Int.random(in: 0..<4, using: &rng) == 0 })
            let newRows = new.map { id -> RemoteQueueItem in
                if id >= 100 { return row(id, "t\(id)") }
                return renamed.contains(id) ? row(id, "r\(id)") : row(id, nil)
            }
            let anchor = new.randomElement(using: &rng)

            let script = QueueEditScript.make(from: old, to: newRows)
            receive(.delta(RemoteQueueDelta(baseSeq: 1, seq: 2, removed: script.removed,
                                            inserted: script.inserted, anchor: anchor,
                                            playback: RemotePlaybackState(), count: newRows.count)))

            let expectedTitles = new.map { renamed.contains($0) ? "r\($0)" : "t\($0)" }
            XCTAssertEqual(mirror.items.map(\.handle), new, "old \(old) → new \(new)")
            XCTAssertEqual(mirror.items.map(\.title), expectedTitles)
            XCTAssertEqual(mirror.items.filter(\.isAnchor).map(\.handle), anchor.map { [$0] } ?? [])
        }
    }

    private func row(_ id: RowHandle, _ title: String?) -> RemoteQueueItem {
        RemoteQueueItem(id: id, title: title, artist: nil, detail: nil)
    }
}
