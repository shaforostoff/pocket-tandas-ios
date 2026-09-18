// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  LibraryEntry.swift
//  Pocket Tandas
//
//  One row in the file browser: a subfolder, an audio file, or a playlist.
//

import Foundation

enum EntryKind {
    case folder
    case audio
    case playlist
}

struct LibraryEntry: Identifiable, Hashable {
    let url: URL
    let kind: EntryKind

    /// The display name, taken once when the entry is listed rather than derived
    /// on each read. `url.lastPathComponent` costs about 8µs — invisible at a
    /// glance, but the arrangement reads the name several times per entry (the
    /// filter, the folder sort, the sort key, the final tiebreak) and re-runs
    /// whenever a scan batch lands. Holding it took a 2000-entry decorate-and-sort
    /// from 22.0ms to 4.8ms.
    let name: String

    var id: URL { url }
    var isFolder: Bool { kind == .folder }

    /// Drillable in the browser: real folders and playlists (opened as fake
    /// folders of their tracks).
    var isNavigable: Bool { kind == .folder || kind == .playlist }

    init(url: URL, kind: EntryKind) {
        self.url = url
        self.kind = kind
        self.name = url.lastPathComponent
    }

    var systemImage: String {
        switch kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .playlist: return "music.note.list"
        }
    }
}
