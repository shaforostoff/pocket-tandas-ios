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
//  This is the most-called function in the app — the browser's filter and sort
//  each ask for every entry's key, and both re-run whenever a scan batch lands —
//  so what it costs to turn a URL into a path matters. `standardizedFileURL` is
//  the expensive way to ask (33.9µs against 2.3µs for `path(percentEncoded:)` on
//  a listing of 1500 real files), and it was being paid twice per call: once for
//  the file and once for a base folder that never changes. Both go away below,
//  without changing a single key: the base is standardized once and remembered,
//  and a file path is only standardized when it actually needs it.
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

    /// Base-relative path if `url` is inside `base`, else nil — a relocatable
    /// identifier (used to persist the queue) that survives the base folder
    /// resolving to a new absolute path across launches.
    static func relativePath(for url: URL, baseURL: URL?) -> String? {
        guard let base = baseURL else { return nil }
        return relativePath(of: url, under: base)
    }

    private static func relativePath(of url: URL, under base: URL) -> String? {
        let basePath = basePath(of: base)
        let filePath = standardizedPath(of: url)
        guard filePath.hasPrefix(basePath) else { return nil }
        var suffix = filePath.dropFirst(basePath.count).drop(while: { $0 == "/" })
        while suffix.last == "/" { suffix = suffix.dropLast() }
        return suffix.isEmpty ? url.lastPathComponent : String(suffix)
    }

    // MARK: - Paths

    /// `url.standardizedFileURL.path`, arrived at the cheap way wherever the path
    /// is already standard — which every URL from a directory listing, a resolved
    /// bookmark or a stored relative path is.
    ///
    /// Standardizing only ever rewrites a path that has an empty, "." or ".."
    /// COMPONENT, or a trailing slash; anything else comes back byte-identical
    /// (verified against the old implementation over every file in the repo and a
    /// list of awkward shapes — see StableTrackIDTests). So a path with none of
    /// those is taken as-is, and only the rest pay for `standardizedFileURL`.
    ///
    /// The component test is what makes this worth doing. "contains a dot after a
    /// slash" would be one line, but it would send every track under a dot-folder
    /// — and every path under a ".git", which is most of a source tree — down the
    /// slow route for nothing: ".hidden" is already standard, only "." and ".."
    /// are not.
    private static func standardizedPath(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard hasNonStandardComponent(path) || path.hasPrefix(Self.firmlinked) else { return path }
        return url.standardizedFileURL.path
    }

    /// The one prefix where standardizing rewrites a path that is otherwise
    /// perfectly well formed: Darwin's firmlinks put /var, /tmp and /etc under
    /// /private, and `standardizedFileURL` maps them back out again while
    /// `path` leaves them where the filesystem put them. FileManager hands back
    /// the /private form, so a listing and a base URL disagree unless both are
    /// standardized. No music library lives here — but the key is persisted, so
    /// it is not somewhere to be approximately right.
    private static let firmlinked = "/private/"

    /// True when `path` holds an empty, "." or ".." component, or ends in a slash
    /// — i.e. when standardizing it would actually change something. One pass over
    /// the bytes; ASCII "/" and "." cannot appear inside a UTF-8 continuation byte,
    /// so this is safe over any name.
    private static func hasNonStandardComponent(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        var afterSlash = false          // the byte just read was a separator
        var dots = 0                    // leading dots of the component being read
        var onlyDots = true             // the component so far is all dots
        for byte in path.utf8 {
            if byte == slash {
                // A component of "", "." or ".." ends here — as does a trailing
                // slash, which is the same test one byte later.
                if afterSlash || (onlyDots && dots > 0 && dots <= 2) { return true }
                afterSlash = true
                dots = 0
                onlyDots = true
            } else {
                afterSlash = false
                if byte == dot && onlyDots { dots += 1 } else { onlyDots = false }
            }
        }
        // End of the path closes the last component the same way a slash would.
        return afterSlash || (onlyDots && dots > 0 && dots <= 2)
    }

    /// The base folder's standardized path, remembered between calls. One entry is
    /// the whole cache because there is one base folder per session; a different
    /// one simply replaces it. Locked because the key is derived on the main actor
    /// and, for a remote add, on the receiver's own hop.
    private static let baseCache = BasePathCache()

    private static func basePath(of base: URL) -> String {
        baseCache.path(of: base)
    }
}

/// Last base folder → its standardized path. See `StableTrackID.baseCache`.
private final class BasePathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var path = ""

    func path(of base: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        if base != url {
            url = base
            path = base.standardizedFileURL.path
        }
        return path
    }
}
