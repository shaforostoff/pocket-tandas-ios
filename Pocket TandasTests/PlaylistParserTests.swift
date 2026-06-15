// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaylistParserTests.swift
//  Pocket TandasTests
//
//  Covers relative-path resolution, comment skipping, the audio-extension
//  fallback, and the filename fallback for foreign absolute paths, using real
//  temp files. Temp dirs are built as directory URLs (isDirectory: true) so
//  relative entries resolve against them instead of dropping a path component.
//

import XCTest
@testable import Pocket_Tandas

final class PlaylistParserTests: XCTestCase {

    func testResolutionRelativeCommentsAndFallback() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString, isDirectory: true)
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

    func testMissingFileMatchesOtherAudioExtension() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString, isDirectory: true)
        let sub = dir.appendingPathComponent("AAA")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // On disk the track is .m4a; the playlist references the old .mp3 name.
        try Data().write(to: sub.appendingPathComponent("BBB.m4a"))

        let urls = PlaylistParser.parseLines("AAA/BBB.mp3", relativeTo: dir)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "BBB.m4a")
    }

    func testMissingFileWithNoAudioVariantIsSkipped() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A sibling with a non-audio extension must NOT be accepted as a match.
        try Data().write(to: dir.appendingPathComponent("BBB.txt"))

        XCTAssertTrue(PlaylistParser.parseLines("BBB.mp3", relativeTo: dir).isEmpty)
    }

    func testLeadingBOMDoesNotSwallowFirstEntry() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("first.mp3"))

        // UTF-8 BOM glued to the first track path, Windows CRLF endings — exactly
        // what a Windows-authored .m3u8 produces.
        let text = "\u{FEFF}first.mp3\r\nmissing.mp3\r\n"
        let urls = PlaylistParser.parseLines(text, relativeTo: dir)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "first.mp3")
    }

    func testWindowsSeparatorsNormalized() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pt-" + UUID().uuidString, isDirectory: true)
        let sub = dir.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data().write(to: sub.appendingPathComponent("c.mp3"))

        let urls = PlaylistParser.parseLines("sub\\c.mp3", relativeTo: dir)
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "c.mp3" })
    }
}
