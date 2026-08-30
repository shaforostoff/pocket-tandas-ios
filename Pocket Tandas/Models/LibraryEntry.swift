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

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isFolder: Bool { kind == .folder }

    /// Drillable in the browser: real folders and playlists (opened as fake
    /// folders of their tracks).
    var isNavigable: Bool { kind == .folder || kind == .playlist }

    var systemImage: String {
        switch kind {
        case .folder: return "folder.fill"
        case .audio: return "music.note"
        case .playlist: return "music.note.list"
        }
    }
}
