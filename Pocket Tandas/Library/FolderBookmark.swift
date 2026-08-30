// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  FolderBookmark.swift
//  Pocket Tandas
//
//  Security-scoped bookmark helpers for persisting access to the user-chosen
//  base folder across launches. On iOS, picker URLs yield security-scoped
//  bookmarks with the default options (the `.withSecurityScope` option is macOS).
//

import Foundation

enum FolderBookmark {
    /// Caller must hold security-scoped access to `url` when calling this.
    static func makeData(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else {
            return nil
        }
        return (url, isStale)
    }
}
