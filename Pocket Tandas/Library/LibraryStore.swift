// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  LibraryStore.swift
//  Pocket Tandas
//
//  Owns the base-folder security-scoped bookmark and resolved URL. Access is
//  acquired once (on pick or on launch-restore) and held for the whole app
//  session, so background playback never loses read access to files mid-track.
//

import Foundation
import Observation

@Observable
final class LibraryStore {
    private(set) var baseURL: URL?
    private(set) var accessError: String?

    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private let bookmarkKey = "baseFolderBookmark"

    var hasBaseFolder: Bool { baseURL != nil }

    init() {
        restore()
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Called with a folder URL from `.fileImporter`.
    func chooseBaseFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            accessError = "Couldn’t access “\(url.lastPathComponent)”."
            return
        }
        if let data = FolderBookmark.makeData(for: url) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        adopt(url)
    }

    /// Resolve the saved bookmark at launch and re-acquire access.
    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey),
              let resolved = FolderBookmark.resolve(data) else { return }
        guard resolved.url.startAccessingSecurityScopedResource() else { return }
        if resolved.isStale, let fresh = FolderBookmark.makeData(for: resolved.url) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        adopt(resolved.url)
    }

    private func adopt(_ url: URL) {
        if let old = scopedURL, old != url {
            old.stopAccessingSecurityScopedResource()
        }
        scopedURL = url
        baseURL = url
        accessError = nil
    }

    /// Disk listing for a folder (unsorted). The browser caches this and sorts
    /// it purely via DirectoryLister.arrange.
    func rawEntries(in folder: URL) -> [LibraryEntry] {
        DirectoryLister.rawEntries(in: folder)
    }

    /// True when `folder` is the base folder (cannot navigate above it).
    func isBaseFolder(_ folder: URL) -> Bool {
        guard let base = baseURL else { return true }
        return folder.standardizedFileURL == base.standardizedFileURL
    }
}
