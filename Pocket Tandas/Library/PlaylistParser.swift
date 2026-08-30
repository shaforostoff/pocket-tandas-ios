// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaylistParser.swift
//  Pocket Tandas
//
//  Parses .m3u / .m3u8 playlists into an ordered list of resolved, existing
//  track URLs. Entries are resolved relative to the playlist's own directory
//  (standard m3u semantics). Foreign absolute paths that don't exist on this
//  device fall back to matching by filename within the playlist's folder, and a
//  reference whose file is missing also matches the same name under another
//  known audio extension (e.g. BBB.mp3 → BBB.m4a); anything still unresolved is
//  skipped rather than crashing.
//

import Foundation

enum PlaylistParser {
    static func parse(playlistURL: URL) -> [URL] {
        guard let data = try? Data(contentsOf: playlistURL) else { return [] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parseLines(text, relativeTo: playlistURL.deletingLastPathComponent())
    }

    static func parseLines(_ text: String, relativeTo directory: URL) -> [URL] {
        var urls: [URL] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }   // blank or #EXTINF/#EXTM3U
            if let resolved = resolve(line, relativeTo: directory) {
                urls.append(resolved)
            }
        }
        return urls
    }

    /// Resolve a single playlist entry to an existing file URL, or nil. Each
    /// candidate location is matched leniently by `existingFile`: if the exact
    /// path is missing, the same name with another audio extension is accepted.
    static func resolve(_ entry: String, relativeTo directory: URL) -> URL? {
        if entry.hasPrefix("file://"), let url = URL(string: entry),
           let found = existingFile(at: url) {
            return found
        }

        // Normalize Windows-style separators for relative entries.
        let normalized = entry.replacingOccurrences(of: "\\", with: "/")

        if normalized.hasPrefix("/") {
            if let found = existingFile(at: URL(fileURLWithPath: normalized)) { return found }
        } else {
            let relative = URL(fileURLWithPath: normalized, relativeTo: directory).standardizedFileURL
            if let found = existingFile(at: relative) { return found }
        }

        // Fallback: same filename inside the playlist's folder (common when a
        // playlist authored elsewhere carries absolute paths).
        let byName = directory.appendingPathComponent((normalized as NSString).lastPathComponent)
        if let found = existingFile(at: byName) { return found }

        return nil
    }

    /// The file at `url` if it exists; otherwise the same path carrying a
    /// different known audio extension (e.g. BBB.mp3 → BBB.m4a), so a playlist
    /// still resolves after a track was re-encoded to another format. The
    /// extensions are tried in a stable order; nil if nothing matches.
    static func existingFile(at url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }

        let base = url.deletingPathExtension()
        let original = url.pathExtension.lowercased()
        for ext in AudioFileTypes.audioExtensions.sorted() where ext != original {
            let candidate = base.appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
