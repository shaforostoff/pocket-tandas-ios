// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaylistWriter.swift
//  Pocket Tandas
//
//  Writes the play queue out as a UTF-8 .m3u8 playlist. Each track is recorded
//  as a path RELATIVE to the folder the playlist is saved in (standard m3u
//  semantics, using forward slashes and "../" when a track sits outside that
//  folder), so the playlist travels with its folder and PlaylistParser resolves
//  the entries straight back.
//

import Foundation

enum PlaylistWriter {
    /// The #EXTM3U body listing each item's path relative to `directory`.
    static func makeContent(for items: [QueueItem], relativeTo directory: URL) -> String {
        var lines = ["#EXTM3U"]
        for item in items {
            lines.append(relativePath(from: directory, to: item.url))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write the queue as `<name>.m3u8` inside `directory`, returning the file
    /// URL. Throws if the write fails (e.g. no write access to the folder).
    @discardableResult
    static func write(items: [QueueItem], name: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(filename(from: name))
        try makeContent(for: items, relativeTo: directory)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A safe `<name>.m3u8` filename: trims, swaps path separators/colons for
    /// dashes, drops any playlist extension the user already typed, and falls
    /// back to "Playlist" when nothing usable remains.
    static func filename(from name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let lower = base.lowercased()
        if lower.hasSuffix(".m3u8") {
            base = String(base.dropLast(5))
        } else if lower.hasSuffix(".m3u") {
            base = String(base.dropLast(4))
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Playlist" }
        return base + ".m3u8"
    }

    /// POSIX relative path from `directory` to `file`: the shared leading path
    /// components are dropped, one ".." is emitted per remaining directory
    /// component, then the rest of the file path is appended. Comparing
    /// standardized `pathComponents` keeps this independent of trailing-slash /
    /// directory-URL quirks.
    static func relativePath(from directory: URL, to file: URL) -> String {
        let dirParts = directory.standardizedFileURL.pathComponents
        let fileParts = file.standardizedFileURL.pathComponents
        var shared = 0
        while shared < dirParts.count, shared < fileParts.count,
              dirParts[shared] == fileParts[shared] {
            shared += 1
        }
        var parts = Array(repeating: "..", count: dirParts.count - shared)
        parts.append(contentsOf: fileParts[shared...])
        return parts.joined(separator: "/")
    }
}
