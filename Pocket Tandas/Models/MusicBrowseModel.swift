// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicBrowseModel.swift
//  Pocket Tandas
//
//  Navigation state for the Music-library browser: a stack of nodes (the file
//  browser's `currentFolder` analogue). The Music library is a typed hierarchy —
//  root categories → containers (an artist/album/genre/playlist) → track lists —
//  so "back" pops the stack rather than walking a path. Screen-scoped: owned by
//  BrowserState (one per main-screen presentation), so it survives the browser
//  view being rebuilt — e.g. on rotation — and resets when the screen is left.
//

import Foundation
import Observation

/// The top-level groupings offered at the Music root, mapping to MPMediaQuery.
enum MusicCategory: String, CaseIterable, Identifiable {
    case playlists, artists, albums, genres, songs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return "Playlists"
        case .artists:   return "Artists"
        case .albums:    return "Albums"
        case .genres:    return "Genres"
        case .songs:     return "Songs"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists:   return "music.mic"
        case .albums:    return "square.stack"
        case .genres:    return "guitars"
        case .songs:     return "music.note"
        }
    }
}

/// A drillable grouping within a category, carrying enough to re-run its query.
struct MusicContainer: Hashable {
    enum Kind: Hashable { case artist, album, genre, playlist }
    let kind: Kind
    let title: String
    let subtitle: String?
    /// Album / playlist persistent id, when the query filters by id.
    let persistentID: UInt64?
    /// Artist / genre name, when the query filters by string property.
    let filterValue: String?

    var systemImage: String {
        switch kind {
        case .artist:   return "music.mic"
        case .album:    return "square.stack"
        case .genre:    return "guitars"
        case .playlist: return "music.note.list"
        }
    }
}

/// One level the browser is showing; the stack's last element is the current view.
enum MusicNode: Hashable {
    case root
    case category(MusicCategory)
    case container(MusicContainer)

    /// Header title for this level.
    var title: String {
        switch self {
        case .root:               return "Music"
        case .category(let c):    return c.title
        case .container(let c):   return c.title
        }
    }

    /// True when this level shows a sortable/filterable list of tracks (rather than
    /// containers or the root tiles). Playlists keep their own listed order.
    var isTrackList: Bool {
        switch self {
        case .category(.songs):            return true
        case .container:                   return true
        default:                           return false
        }
    }

    var isPlaylist: Bool {
        if case .container(let c) = self, c.kind == .playlist { return true }
        return false
    }

    /// A stable token used to scope prelisten auto-advance to this exact level
    /// (the Music analogue of the file browser's folder URL).
    var contextURL: URL? { URL(string: "musiclib://\(contextKey)") }

    private var contextKey: String {
        switch self {
        case .root:
            return "root"
        case .category(let c):
            return "cat/\(c.rawValue)"
        case .container(let c):
            let ident = c.persistentID.map(String.init) ?? (c.filterValue ?? c.title)
            return "con/\(c.kind)/\(ident.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x")"
        }
    }
}

@Observable
final class MusicBrowseModel {
    private(set) var stack: [MusicNode] = [.root]

    var current: MusicNode { stack.last ?? .root }
    var canGoUp: Bool { stack.count > 1 }

    func push(_ node: MusicNode) { stack.append(node) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
    func reset() { stack = [.root] }
}
