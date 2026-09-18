// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StableTrackIDTests.swift
//  Pocket TandasTests
//
//  The key is a PERSISTED identity — it is what the metadata cache, the analysis
//  cache and the saved queue are all keyed by — so the thing worth testing is not
//  that it returns something sensible but that it returns exactly what it used to.
//  `standardizedPath` below is the reference: the plain `standardizedFileURL`
//  derivation the fast path replaced. Every case asserts the two agree.
//

import XCTest
@testable import Pocket_Tandas

final class StableTrackIDTests: XCTestCase {

    /// How the key was derived before the fast path — the oracle for every case.
    private func referenceKey(for url: URL, baseURL: URL?) -> String {
        if let base = baseURL, let relative = referenceRelative(of: url, under: base) {
            return relative
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(url.lastPathComponent)|\(size)"
    }

    private func referenceRelative(of url: URL, under base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return nil }
        let suffix = filePath.dropFirst(basePath.count)
        return suffix.drop(while: { $0 == "/" }).isEmpty
            ? url.lastPathComponent
            : String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func assertMatchesReference(_ url: URL, base: URL?,
                                        _ message: String = "",
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StableTrackID.key(for: url, baseURL: base),
                       referenceKey(for: url, baseURL: base),
                       "key \(message)", file: file, line: line)
        XCTAssertEqual(StableTrackID.relativePath(for: url, baseURL: base),
                       base.flatMap { referenceRelative(of: url, under: $0) },
                       "relativePath \(message)", file: file, line: line)
    }

    private let base = URL(fileURLWithPath: "/Users/dj/Music/Tango", isDirectory: true)

    /// The shape the fast path is for: an ordinary listing, taken as-is.
    func testPlainPathsAreUnchanged() {
        for name in ["Troilo/1941/Maragata.m4a", "top.mp3", "a/b/c/d/e/f/deep.flac"] {
            assertMatchesReference(base.appendingPathComponent(name), base: base, name)
        }
    }

    /// The components that DO need standardizing, which is the whole risk: each
    /// must still fall back and produce the old answer.
    func testNonStandardComponentsStillStandardize() {
        for name in ["Troilo/../DiSarli/Bahía Blanca.m4a", "Troilo/./Cachirulo.m4a",
                     "sub//double.mp3", "trail/", "dot/.", "dotdot/.."] {
            assertMatchesReference(base.appendingPathComponent(name), base: base, name)
            assertMatchesReference(URL(fileURLWithPath: base.path + "/" + name), base: base, name)
        }
    }

    /// A dot-DIRECTORY is already standard. This is the case the component test
    /// exists to keep on the fast path, so it is worth pinning that it is correct
    /// there — ".hidden" must not be mistaken for ".".
    func testDotDirectoriesAreNotTreatedAsDotComponents() {
        for name in [".hidden/x.mp3", "x..y/d.mp3", "..c/d.mp3", "c..", ".git/objects/ab/cdef"] {
            assertMatchesReference(base.appendingPathComponent(name), base: base, name)
        }
    }

    /// Names that exercise percent-encoding, which is the other way `path` and
    /// `standardizedFileURL.path` could have diverged.
    func testAwkwardNames() {
        for name in ["Ñ oddities/año ñandú [1941] #2.m4a", "Percent %20 name.mp3",
                     "quote'and\"marks.mp3", "tab\there.mp3", "plus+amp&.mp3"] {
            assertMatchesReference(base.appendingPathComponent(name), base: base, name)
        }
    }

    func testOutsideTheBaseAndDegenerateBases() {
        assertMatchesReference(URL(fileURLWithPath: "/Users/dj/Elsewhere/out.mp3"), base: base, "outside")
        assertMatchesReference(base, base: base, "the base itself")
        assertMatchesReference(base.appendingPathComponent("x.mp3"), base: nil, "no base")
        assertMatchesReference(base.appendingPathComponent("x.mp3"),
                               base: URL(fileURLWithPath: "/"), "root base")
        // A base given without the directory flag must key the same as one with it.
        assertMatchesReference(base.appendingPathComponent("x.mp3"),
                               base: URL(fileURLWithPath: "/Users/dj/Music/Tango"), "non-directory base")
    }

    /// The base path is remembered between calls, so switching base folders — and
    /// switching back — has to keep giving each one its own answer.
    func testSwitchingBaseFolders() {
        let other = URL(fileURLWithPath: "/Users/dj/Music/Vals", isDirectory: true)
        let track = base.appendingPathComponent("Troilo/Maragata.m4a")
        for _ in 0..<3 {
            XCTAssertEqual(StableTrackID.key(for: track, baseURL: base), "Troilo/Maragata.m4a")
            XCTAssertEqual(StableTrackID.key(for: track, baseURL: other),
                           referenceKey(for: track, baseURL: other))
        }
    }

    /// Real files, from a real listing — the paths the browser actually hands it.
    func testAgainstARealDirectoryListing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StableTrackIDTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let nested = root.appendingPathComponent("Aníbal Troilo/1941", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["Maragata.m4a", "año ñandú.flac", "plain.mp3"] {
            try Data("x".utf8).write(to: nested.appendingPathComponent(name))
        }
        let listed = try fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil)
        XCTAssertEqual(listed.count, 3)
        for url in listed { assertMatchesReference(url, base: root, url.lastPathComponent) }
    }
}
