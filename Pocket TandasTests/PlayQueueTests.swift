// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlayQueueTests.swift
//  Pocket TandasTests
//
//  Covers the live "what plays next" read and the editing operations, including
//  the case the engine relies on: inserting after the current item changes what
//  item(after:) returns immediately.
//

import XCTest
@testable import Pocket_Tandas

final class PlayQueueTests: XCTestCase {

    private func makeItem(_ name: String) -> QueueItem {
        QueueItem(url: URL(fileURLWithPath: "/music/\(name).mp3"), trackKey: name)
    }

    func testItemAfterReturnsNextThenNil() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.append(a); q.append(b)
        XCTAssertEqual(q.item(after: a.id)?.id, b.id)
        XCTAssertNil(q.item(after: b.id))
    }

    func testInsertAfterCurrentChangesNextLive() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.append(a); q.append(b)
        XCTAssertEqual(q.item(after: a.id)?.id, b.id)
        // Insert c directly after a — the next read must now return c.
        q.insert(c, after: a.id)
        XCTAssertEqual(q.item(after: a.id)?.id, c.id)
    }

    func testRemove() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.append(a); q.append(b)
        q.remove(a.id)
        XCTAssertEqual(q.items.count, 1)
        XCTAssertEqual(q.items.first?.id, b.id)
        XCTAssertNil(q.item(after: b.id))
    }

    func testMove() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.append(a); q.append(b); q.append(c)
        q.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)  // c to front
        XCTAssertEqual(q.items.map(\.trackKey), ["c", "a", "b"])
    }

    func testPinnedTrackCannotBeMoved() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.append(a); q.append(b); q.append(c)
        // b (index 1) is the playing track — dragging it is rejected.
        q.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, pinnedID: b.id)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "b", "c"])
    }

    func testMovingAnotherTrackAcrossThePinnedTrackIsAllowed() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.append(a); q.append(b); q.append(c)
        // b is playing (pinned). Drag c from below to above b.
        q.move(fromOffsets: IndexSet(integer: 2), toOffset: 1, pinnedID: b.id)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "c", "b"])
        // The engine reads the new neighbour live: b is now last.
        XCTAssertNil(q.item(after: b.id))
    }

    func testItemAfterUnknownIDIsNil() {
        let q = PlayQueue()
        q.append(makeItem("a"))
        XCTAssertNil(q.item(after: UUID()))
    }
}
