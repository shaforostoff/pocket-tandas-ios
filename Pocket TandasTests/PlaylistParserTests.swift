// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaylistParserTests.swift
//  Pocket TandasTests
//
//  Covers relative-path resolution, comment skipping, and the filename fallback
//  for foreign absolute paths, using real temp files.
//

import XCTest
@testable import Pocket_Tandas

final class PlaylistParserTests: XCTestCase {

    func testResolutionRelativeCommentsAndFallback() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("a.mp3"))
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("b.mp3"))

        let text = """
        #EXTM3U
        #EXTINF:123,Some Artist - Some Title
        a.mp3
        sub/b.mp3
        /Volumes/OtherMac/Music/a.mp3
        missing.mp3
        """

        let urls = PlaylistParser.parseLines(text, relativeTo: dir)

        // a.mp3 (relative) and sub/b.mp3 (relative subfolder) resolve.
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "a.mp3" })
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "b.mp3" })
        // The foreign absolute path falls back to the matching filename in dir.
        XCTAssertEqual(urls.filter { $0.lastPathComponent == "a.mp3" }.count, 2)
        // A truly missing file is skipped (not crashed on).
        XCTAssertFalse(urls.contains { $0.lastPathComponent == "missing.mp3" })
    }

    func testWindowsSeparatorsNormalized() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString)
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: sub.appendingPathComponent("c.mp3"))

        let urls = PlaylistParser.parseLines("sub\\c.mp3", relativeTo: dir)
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "c.mp3" })
    }
}
