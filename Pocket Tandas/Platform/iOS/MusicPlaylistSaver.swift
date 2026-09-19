// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicPlaylistSaver.swift
//  Pocket Tandas
//
//  Saves the play queue as a new playlist in the device Music library — the
//  library counterpart of PlaylistWriter, and its exact mirror image. An .m3u8
//  can only hold FILE tracks (PlaylistWriter skips media items); a library
//  playlist can only hold LIBRARY tracks (this skips file items). A queue mixing
//  both round-trips through neither, so each save reports what it left behind.
//
//  Everything here goes through MediaPlayer. MPMediaPlaylist.add(_:) takes
//  MPMediaItem objects directly, and the queue already holds the
//  MPMediaItem.persistentIDs the Music browser put there, so the tracks that land
//  in the playlist are exactly the ones the DJ queued. No matching, no
//  heuristics, nothing that can quietly substitute a different recording.
//
//  EVERY SAVE MAKES A NEW PLAYLIST, even under a name already in the library.
//  Replacing an existing one was offered once and has been removed:
//  MPMediaPlaylist is append-only, so the only route was
//  MusicKit.MusicLibrary.edit(_:items:) — which needed each track's MusicItemID
//  guessed from its MPMediaItem.persistentID, and which in practice could simply
//  never return, leaving Save disabled until the app was restarted. Neither
//  framework can DELETE a playlist, so a replace that went wrong left nothing to
//  undo it with. Two playlists sharing a name is the milder failure: Music allows
//  it, and the user can delete the old one in the Music app.
//

import Foundation
import MediaPlayer

/// What a save actually did — every count here is something we know for a fact,
/// so the confirmation can be specific without overclaiming.
struct MusicPlaylistSaveResult {
    let name: String
    /// Library tracks written to the playlist, in queue order (duplicates kept).
    let submitted: Int
    /// Queue entries that were folder files — a library playlist can't hold them.
    let filesSkipped: Int
    /// Distinct titles of library tracks that couldn't be written, having left
    /// the library since they were queued.
    let unmatched: [String]
    /// MPMediaEntity persistent id of the playlist this save created, so the
    /// browser can jump straight to it.
    let libraryPlaylistID: UInt64
}

enum MusicPlaylistSaveError: LocalizedError {
    case notAuthorized(MPMediaLibraryAuthorizationStatus)
    case noLibraryTracks
    case nothingResolved
    case playlistNotCreated

    var errorDescription: String? {
        switch self {
        case .notAuthorized(.denied), .notAuthorized(.restricted):
            return "Pocket Tandas doesn't have permission to change your Music "
                 + "library. Grant Media & Apple Music access in Settings › Privacy."
        case .notAuthorized:
            return "Music-library access wasn't granted."
        case .noLibraryTracks:
            return "The queue has no Music-library tracks. Only tracks added from "
                 + "Music can go in a Music playlist — save the rest as an .m3u8."
        case .nothingResolved:
            return "None of the queue's Music tracks are still in your library. "
                 + "They may have been removed since they were added."
        case .playlistNotCreated:
            return "Your Music library didn't create the playlist. Try again."
        }
    }
}

enum MusicPlaylistSaver {

    // MARK: - Saving

    /// Write `items` to a new library playlist called `name`. Returns what went in
    /// and what didn't; throws only when nothing could be saved at all.
    static func save(items: [QueueItem], name: String) async throws -> MusicPlaylistSaveResult {
        // The grant the app already asked for before the Music browser listed
        // anything, so this normally returns without prompting.
        let status = await MediaLibraryImporter.requestAuthorization()
        guard status == .authorized else { throw MusicPlaylistSaveError.notAuthorized(status) }

        let queued = items.compactMap(QueuedTrack.init(queueItem:))
        guard !queued.isEmpty else { throw MusicPlaylistSaveError.noLibraryTracks }
        let filesSkipped = items.count - queued.count

        // Map the ORDERED queue through the lookup: order is the whole point of a
        // DJ set, and a repeat (the same cortina between every tanda) has to come
        // out as a repeat rather than being collapsed into one entry.
        let index = libraryIndex(for: Set(queued.map(\.persistentID)))
        let mediaItems = queued.compactMap { index[$0.persistentID] }
        guard !mediaItems.isEmpty else { throw MusicPlaylistSaveError.nothingResolved }

        var unmatched: [String] = []
        var seen: Set<UInt64> = []
        for track in queued where index[track.persistentID] == nil {
            if seen.insert(track.persistentID).inserted { unmatched.append(track.title) }
        }

        return try await create(named: displayName(from: name), with: mediaItems,
                                filesSkipped: filesSkipped, unmatched: unmatched)
    }

    /// Trimmed, with a fallback so an empty field still produces a named playlist.
    /// Unlike PlaylistWriter.filename(from:) nothing is substituted for "/" or
    /// ":" — a playlist name is not a filename, and Music accepts both.
    static func displayName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Playlist" : trimmed
    }

    // MARK: - Creating

    /// A new playlist holding exactly `mediaItems`, in order.
    private static func create(named title: String, with mediaItems: [MPMediaItem],
                               filesSkipped: Int,
                               unmatched: [String]) async throws -> MusicPlaylistSaveResult {
        let metadata = MPMediaPlaylistCreationMetadata(name: title)
        metadata.authorDisplayName = "Pocket Tandas"
        // A FRESH uuid every time. getPlaylist(with:) is keyed by the uuid and
        // ignores the creation metadata when one already exists, so reusing a uuid
        // would hand back the old playlist and APPEND to it.
        let playlist = try await makePlaylist(uuid: UUID(), metadata: metadata)
        try await append(mediaItems, to: playlist)
        return MusicPlaylistSaveResult(name: title, submitted: mediaItems.count,
                                       filesSkipped: filesSkipped, unmatched: unmatched,
                                       libraryPlaylistID: playlist.persistentID)
    }

    private static func makePlaylist(uuid: UUID,
                                     metadata: MPMediaPlaylistCreationMetadata) async throws -> MPMediaPlaylist {
        try await withCheckedThrowingContinuation { cont in
            MPMediaLibrary.default().getPlaylist(with: uuid, creationMetadata: metadata) { playlist, error in
                if let playlist {
                    cont.resume(returning: playlist)
                } else {
                    cont.resume(throwing: error ?? MusicPlaylistSaveError.playlistNotCreated)
                }
            }
        }
    }

    private static func append(_ items: [MPMediaItem], to playlist: MPMediaPlaylist) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            playlist.add(items) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    // MARK: - Library lookup

    /// One queue media entry reduced to what a save needs: the id to look up, and
    /// the title captured at enqueue — used only to name a track that has since
    /// left the library, where there is no MPMediaItem left to ask.
    private struct QueuedTrack {
        let persistentID: UInt64
        let title: String

        init?(queueItem item: QueueItem) {
            guard let ref = item.mediaRef else { return nil }
            persistentID = ref.persistentID
            title = item.mediaSnapshot?.title ?? ref.displayTitle
        }
    }

    /// Every wanted id resolved in ONE library sweep rather than a filtered query
    /// each — see PlayQueue.mediaIndex(for:), which had to learn the same lesson
    /// (a thousand-track queue was a thousand MPMediaQuery round-trips). The
    /// MPMediaItems themselves are kept here, since add(_:) takes the
    /// objects, but only persistentID is read off them so their property caches
    /// stay small and they are released when the save returns.
    private static func libraryIndex(for wanted: Set<UInt64>) -> [UInt64: MPMediaItem] {
        var index: [UInt64: MPMediaItem] = [:]
        index.reserveCapacity(wanted.count)
        for item in MPMediaQuery.songs().items ?? [] where wanted.contains(item.persistentID) {
            index[item.persistentID] = item
        }
        return index
    }
}
