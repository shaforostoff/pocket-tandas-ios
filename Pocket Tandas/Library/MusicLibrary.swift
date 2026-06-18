// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicLibrary.swift
//  Pocket Tandas
//
//  Thin MPMediaQuery wrapper backing the Music-library browser — the
//  DirectoryLister analogue. Returns the drillable containers for a category
//  (playlists/artists/albums/genres) and the tracks for a category or container.
//  Synchronous: MPMediaQuery hits an indexed on-device database and is fast enough
//  to call from the view. Returns empty when Music access hasn't been granted.
//

import Foundation
import MediaPlayer

enum MusicLibrary {

    /// The drillable groupings within a category. `.songs` is a flat track list and
    /// has no containers.
    static func containers(for category: MusicCategory) -> [MusicContainer] {
        switch category {
        case .playlists: return playlistContainers()
        case .artists:   return artistContainers()
        case .albums:    return albumContainers()
        case .genres:    return genreContainers()
        case .songs:     return []
        }
    }

    /// The tracks shown at a node: the Songs category (whole library) or a
    /// container's contents. Other nodes have no tracks.
    static func tracks(in node: MusicNode) -> [MPMediaItem] {
        switch node {
        case .category(.songs):  return MPMediaQuery.songs().items ?? []
        case .container(let c):  return tracks(in: c)
        default:                 return []
        }
    }

    // MARK: - Containers

    private static func playlistContainers() -> [MusicContainer] {
        (MPMediaQuery.playlists().collections ?? []).map { collection in
            let name = (collection.value(forProperty: MPMediaPlaylistPropertyName) as? String) ?? "Playlist"
            let pid = (collection.value(forProperty: MPMediaPlaylistPropertyPersistentID) as? NSNumber)?.uint64Value
            return MusicContainer(kind: .playlist, title: name, subtitle: nil,
                                  persistentID: pid, filterValue: nil)
        }
    }

    private static func artistContainers() -> [MusicContainer] {
        (MPMediaQuery.artists().collections ?? []).compactMap { collection in
            guard let artist = collection.representativeItem?.artist, !artist.isEmpty else { return nil }
            return MusicContainer(kind: .artist, title: artist, subtitle: nil,
                                  persistentID: nil, filterValue: artist)
        }
    }

    private static func albumContainers() -> [MusicContainer] {
        (MPMediaQuery.albums().collections ?? []).compactMap { collection in
            guard let rep = collection.representativeItem else { return nil }
            let title = rep.albumTitle ?? "Unknown Album"
            return MusicContainer(kind: .album, title: title, subtitle: rep.albumArtist ?? rep.artist,
                                  persistentID: rep.albumPersistentID, filterValue: nil)
        }
    }

    private static func genreContainers() -> [MusicContainer] {
        (MPMediaQuery.genres().collections ?? []).compactMap { collection in
            guard let genre = collection.representativeItem?.genre, !genre.isEmpty else { return nil }
            return MusicContainer(kind: .genre, title: genre, subtitle: nil,
                                  persistentID: nil, filterValue: genre)
        }
    }

    // MARK: - Tracks

    private static func tracks(in container: MusicContainer) -> [MPMediaItem] {
        switch container.kind {
        case .album:
            guard let pid = container.persistentID else { return [] }
            let query = MPMediaQuery.albums()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                              forProperty: MPMediaItemPropertyAlbumPersistentID))
            return query.items ?? []
        case .artist:
            guard let name = container.filterValue else { return [] }
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: name,
                                                              forProperty: MPMediaItemPropertyArtist))
            return query.items ?? []
        case .genre:
            guard let name = container.filterValue else { return [] }
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: name,
                                                              forProperty: MPMediaItemPropertyGenre))
            return query.items ?? []
        case .playlist:
            guard let pid = container.persistentID else { return [] }
            let query = MPMediaQuery.playlists()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                              forProperty: MPMediaPlaylistPropertyPersistentID))
            // A playlist keeps its own listed order.
            return query.collections?.first?.items ?? []
        }
    }
}
