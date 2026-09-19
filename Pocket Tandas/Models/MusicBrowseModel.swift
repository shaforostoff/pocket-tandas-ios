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

    /// Bumped to make the browser re-read the level it is already on. A node is a
    /// value, so standing still is otherwise indistinguishable from a listing that
    /// hasn't changed — and the library can change under us, e.g. when this app
    /// writes a playlist into it.
    private(set) var revision = 0

    /// A playlist this app has just saved, for the browser to bring into view once
    /// the Playlists listing has rebuilt. Cleared once shown, once given up on, or
    /// as soon as the user browses somewhere it could not appear.
    var pendingReveal: PendingReveal?

    struct PendingReveal: Equatable {
        let persistentID: UInt64
        /// Set once the browser has re-read the library waiting for it to show up.
        var retried = false
    }

    var current: MusicNode { stack.last ?? .root }
    var canGoUp: Bool { stack.count > 1 }

    /// What the browser should be showing: the level, plus the counter that tells
    /// a deliberate re-read apart from the level simply not having moved.
    var listingToken: ListingToken { ListingToken(node: current, revision: revision) }

    struct ListingToken: Equatable {
        let node: MusicNode
        let revision: Int
    }

    func push(_ node: MusicNode) { stack.append(node) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
    func reset() { stack = [.root] }

    /// Re-read the current level in place.
    func refresh() { revision += 1 }

    /// Show the Playlists category — freshly read even when it is already open —
    /// so a playlist just written to the library is on screen without the user
    /// having to go looking for it. `persistentID` is the new playlist's, scrolled
    /// to when the listing has it.
    func showPlaylists(revealing persistentID: UInt64) {
        stack = [.root, .category(.playlists)]
        pendingReveal = PendingReveal(persistentID: persistentID)
        revision += 1
    }
}
