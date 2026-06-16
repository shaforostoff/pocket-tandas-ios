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
        q.enqueue(a); q.enqueue(b)
        XCTAssertEqual(q.item(after: a.id)?.id, b.id)
        XCTAssertNil(q.item(after: b.id))
    }

    func testInsertAfterCurrentChangesNextLive() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b)
        XCTAssertEqual(q.item(after: a.id)?.id, b.id)
        // Insert c directly after a — the next read must now return c.
        q.insert(c, after: a.id)
        XCTAssertEqual(q.item(after: a.id)?.id, c.id)
    }

    func testRemove() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.enqueue(a); q.enqueue(b)
        q.remove(a.id)
        XCTAssertEqual(q.items.count, 1)
        XCTAssertEqual(q.items.first?.id, b.id)
        XCTAssertNil(q.item(after: b.id))
    }

    func testMove() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        q.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)  // c to front
        XCTAssertEqual(q.items.map(\.trackKey), ["c", "a", "b"])
    }

    func testPinnedTrackCannotBeMoved() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        // b (index 1) is the playing track — dragging it is rejected.
        q.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, pinnedID: b.id)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "b", "c"])
    }

    func testMovingAnotherTrackAcrossThePinnedTrackIsAllowed() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        // b is playing (pinned). Drag c from below to above b.
        q.move(fromOffsets: IndexSet(integer: 2), toOffset: 1, pinnedID: b.id)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "c", "b"])
        // The engine reads the new neighbour live: b is now last.
        XCTAssertNil(q.item(after: b.id))
    }

    func testItemAfterUnknownIDIsNil() {
        let q = PlayQueue()
        q.enqueue(makeItem("a"))
        XCTAssertNil(q.item(after: UUID()))
    }

    // MARK: - Insert anchor

    func testEnqueueAppendsAtEndWithoutAnchor() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.enqueue(a); q.enqueue(b)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "b"])
        XCTAssertNil(q.anchorID)
    }

    func testEnqueueInsertsAboveAnchor() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b)
        q.setAnchor(b.id)
        q.enqueue(c)                                     // lands above the anchor (b)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "c", "b"])
        XCTAssertEqual(q.anchorID, b.id)                 // anchor unchanged
    }

    func testEnqueueContentsOfInsertsBlockAboveAnchorInOrder() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c"), d = makeItem("d")
        q.enqueue(a); q.enqueue(b)
        q.setAnchor(b.id)
        q.enqueue(contentsOf: [c, d])
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "c", "d", "b"])
    }

    func testSuccessiveEnqueuesStackAboveAnchorInOrder() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a)
        q.setAnchor(a.id)
        q.enqueue(b); q.enqueue(c)
        XCTAssertEqual(q.items.map(\.trackKey), ["b", "c", "a"])
    }

    func testSetAnchorNilClears() {
        let q = PlayQueue()
        let a = makeItem("a")
        q.enqueue(a)
        q.setAnchor(a.id)
        XCTAssertEqual(q.anchorID, a.id)
        q.setAnchor(nil)
        XCTAssertNil(q.anchorID)
    }

    func testClearAnchorIfMatches() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.enqueue(a); q.enqueue(b)
        q.setAnchor(b.id)
        q.clearAnchor(ifMatches: a.id)   // not the anchor — unchanged
        XCTAssertEqual(q.anchorID, b.id)
        q.clearAnchor(ifMatches: b.id)   // the anchor plays — cleared
        XCTAssertNil(q.anchorID)
    }

    func testRemovingAnchoredItemClearsAnchor() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b")
        q.enqueue(a); q.enqueue(b)
        q.setAnchor(b.id)
        q.remove(b.id)
        XCTAssertNil(q.anchorID)
        // With the anchor gone, new tracks append at the end again.
        let c = makeItem("c")
        q.enqueue(c)
        XCTAssertEqual(q.items.map(\.trackKey), ["a", "c"])
    }

    func testRemoveAtOffsetsClearsAnchorWhenAnchoredItemRemoved() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        q.setAnchor(b.id)
        q.remove(atOffsets: IndexSet(integer: 1))   // removes b
        XCTAssertNil(q.anchorID)
    }

    func testRemoveAtOffsetsKeepsAnchorWhenOtherItemRemoved() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        q.setAnchor(b.id)
        q.remove(atOffsets: IndexSet(integer: 0))   // removes a
        XCTAssertEqual(q.anchorID, b.id)
    }

    func testRemoveAllClearsAnchor() {
        let q = PlayQueue()
        let a = makeItem("a")
        q.enqueue(a)
        q.setAnchor(a.id)
        q.removeAll()
        XCTAssertNil(q.anchorID)
    }

    func testMovePreservesAnchorAndInsertsAtNewPosition() {
        let q = PlayQueue()
        let a = makeItem("a"), b = makeItem("b"), c = makeItem("c")
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        q.setAnchor(c.id)
        q.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)   // c to front
        XCTAssertEqual(q.anchorID, c.id)                          // anchor follows c
        let d = makeItem("d")
        q.enqueue(d)                                              // above c's new position
        XCTAssertEqual(q.items.map(\.trackKey), ["d", "c", "a", "b"])
    }

    // MARK: - Persistence

    func testPersistenceIsRelocatableAcrossBasePath() throws {
        let fm = FileManager.default
        let store = fm.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: store) }

        // Base A holds Album/01.mp3.
        let baseA = fm.temporaryDirectory.appendingPathComponent("pt-A-\(UUID().uuidString)", isDirectory: true)
        let album = baseA.appendingPathComponent("Album", isDirectory: true)
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        let track = album.appendingPathComponent("01.mp3")
        try Data().write(to: track)

        // Session 1: enable persistence under base A and queue the track.
        let q1 = PlayQueue(storeURL: store)
        q1.restore(baseURL: baseA)
        q1.enqueue(QueueItem(url: track, trackKey: StableTrackID.key(for: track, baseURL: baseA)))
        XCTAssertEqual(q1.items.count, 1)

        // The base folder now lives at a NEW absolute path (B), as iOS may re-grant.
        let baseB = fm.temporaryDirectory.appendingPathComponent("pt-B-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: baseA, to: baseB)
        defer { try? fm.removeItem(at: baseB) }

        // Session 2: restoring against base B resolves the relative entry under B.
        let q2 = PlayQueue(storeURL: store)
        q2.restore(baseURL: baseB)
        XCTAssertEqual(q2.items.count, 1)
        let restored = try XCTUnwrap(q2.items.first)
        XCTAssertTrue(restored.url.path.hasSuffix("Album/01.mp3"))
        XCTAssertTrue(restored.url.path.contains(baseB.lastPathComponent))
        XCTAssertTrue(fm.fileExists(atPath: restored.url.path))
    }

    func testPersistenceDropsMissingFiles() throws {
        let fm = FileManager.default
        let store = fm.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: store) }
        let base = fm.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let track = base.appendingPathComponent("gone.mp3")
        try Data().write(to: track)

        let q1 = PlayQueue(storeURL: store)
        q1.restore(baseURL: base)
        q1.enqueue(QueueItem(url: track, trackKey: StableTrackID.key(for: track, baseURL: base)))

        try fm.removeItem(at: track)   // the file disappears between launches

        let q2 = PlayQueue(storeURL: store)
        q2.restore(baseURL: base)
        XCTAssertTrue(q2.items.isEmpty)
    }
}
