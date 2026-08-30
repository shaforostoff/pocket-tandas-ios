// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StableTrackID.swift
//  Pocket Tandas
//
//  Derives the cache key for a track: base-relative path + file size. Keying on
//  the path relative to the base folder (rather than the absolute URL) means the
//  cache survives the base folder being re-granted at a different absolute path.
//  Falls back to the filename for files outside the base tree (e.g. playlist
//  targets).
//

import Foundation

enum StableTrackID {
    static func key(for url: URL, baseURL: URL?) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let relative = baseURL.flatMap { relativePath(of: url, under: $0) } ?? url.lastPathComponent
        return "\(relative)|\(size)"
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
