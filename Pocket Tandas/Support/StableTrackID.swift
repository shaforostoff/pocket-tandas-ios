// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StableTrackID.swift
//  Pocket Tandas
//
//  Derives the cache key for a track: the base-relative path for files inside the
//  base folder — unique on its own, and stable when the base folder is re-granted
//  at a different absolute path. Files outside the base tree (e.g. playlist
//  targets) fall back to "filename|size", where the size disambiguates same-named
//  files in different folders. Change detection lives in the staleness check
//  (mod-date + size), not in the key, so the hot path avoids a file-size stat.
//

import Foundation

enum StableTrackID {
    static func key(for url: URL, baseURL: URL?) -> String {
        // In-base files: the base-relative path is already unique, so it alone is
        // the key — no file-size stat in this hot path (sort/filter/rows call it
        // repeatedly). Size moves to the staleness check instead.
        if let base = baseURL, let relative = relativePath(of: url, under: base) {
            return relative
        }
        // Outside the base tree (or no base chosen): the bare filename collides
        // across folders, so disambiguate with the file size.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "\(url.lastPathComponent)|\(size)"
    }

    private static func relativePath(of url: URL, under base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else { return nil }
        let suffix = filePath.dropFirst(basePath.count)
        return suffix.drop(while: { $0 == "/" }).isEmpty ? url.lastPathComponent
                                                          : String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
