// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicPlaylistSaver.swift
//  Pocket Tandas
//
//  Saves the play queue as a playlist in the device Music library — the library
//  counterpart of PlaylistWriter, and its exact mirror image. An .m3u8 can only
//  hold FILE tracks (PlaylistWriter skips media items); a library playlist can
//  only hold LIBRARY tracks (this skips file items). A queue mixing both
//  round-trips through neither, so each save reports what it left behind.
//
//  TWO frameworks, split by what each one can actually do:
//
//   - CREATING a playlist goes through MediaPlayer. MPMediaPlaylist.add(_:)
//     takes MPMediaItem objects directly, and the queue already holds the
//     MPMediaItem.persistentIDs the Music browser put there, so the tracks that
//     land in the playlist are exactly the ones the DJ queued. No matching, no
//     heuristics, nothing that can quietly substitute a different recording.
//   - REPLACING one's contents goes through MusicKit. MPMediaPlaylist is
//     append-only — no remove, no reorder, no replace — and neither framework has
//     a delete, so MusicKit.MusicLibrary.edit(_:items:) is the only way in either
//     of them to make an existing playlist hold the current queue.
//
//  edit() wants MusicKit Songs, and Apple documents no mapping between
//  MPMediaItem.persistentID and MusicItemID. In practice a local library song's
//  MusicItemID is its persistentID in decimal, so that is tried first as one bulk
//  request; whatever it misses falls back to a per-track title query scored on
//  artist and duration (see resolve(_:)). That guesswork is now confined to the
//  replace path — a first save never depends on it.
//
//  Because MediaPlayer creates the playlist, a later replace has to be able to
//  find it again as a MusicKit Playlist; linkForLaterReplace(_:named:) does that
//  once, at creation, and refuses to store a link it cannot prove is ours.
//
//  Note the module-qualified MusicKit.MusicLibrary below: this project has its own
//  `enum MusicLibrary` (the MPMediaQuery wrapper next door), and inside the module
//  the bare name resolves to that one.
//

import Foundation
import MediaPlayer
import MusicKit

/// What a save actually did — every count here is something we know for a fact,
/// so the confirmation can be specific without overclaiming.
struct MusicPlaylistSaveResult {
    let name: String
    /// True when an existing app-created playlist had its contents replaced
    /// rather than a new playlist being created.
    let replacedExisting: Bool
    /// Library tracks written to the playlist, in queue order (duplicates kept).
    let submitted: Int
    /// Queue entries that were folder files — a library playlist can't hold them.
    let filesSkipped: Int
    /// Distinct titles of library tracks that couldn't be written: gone from the
    /// library, or (replacing only) not matchable back to a MusicKit Song.
    let unmatched: [String]
}

enum MusicPlaylistSaveError: LocalizedError {
    case notAuthorized(MPMediaLibraryAuthorizationStatus)
    case noLibraryTracks
    case nothingResolved
    case replaceUnavailable(String)
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
        case .replaceUnavailable(let name):
            return "“\(name)” couldn't be updated. Save the queue as a new "
                 + "playlist instead."
        case .playlistNotCreated:
            return "Your Music library didn't create the playlist. Try again."
        }
    }
}

enum MusicPlaylistSaver {

    // MARK: - Saving

    /// Write `items` to a library playlist called `name`, replacing the contents
    /// of the one we made under that name if it is still there. Returns what went
    /// in and what didn't; throws only when nothing could be saved at all.
    static func save(items: [QueueItem], name: String,
                     replacingExisting: Bool = true) async throws -> MusicPlaylistSaveResult {
        // MediaPlayer gates both paths: the create path writes through it, and the
        // replace path still reads the queue's tracks out of MPMediaQuery first.
        // It is also the grant the app already asked for before the Music browser
        // listed anything, so this normally returns without prompting.
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

        let title = displayName(from: name)
        if replacingExisting, let existing = await ownedPlaylist(named: title) {
            return try await replace(existing, named: title, with: mediaItems,
                                     filesSkipped: filesSkipped, unmatched: unmatched)
        }
        return try await create(named: title, with: mediaItems,
                                filesSkipped: filesSkipped, unmatched: unmatched)
    }

    /// Whether saving under `name` would replace a playlist this app made — the
    /// caller asks before saving so the user can confirm or pick a new one.
    static func wouldReplacePlaylist(named name: String) async -> Bool {
        await ownedPlaylist(named: displayName(from: name)) != nil
    }

    /// Trimmed, with a fallback so an empty field still produces a named playlist.
    /// Unlike PlaylistWriter.filename(from:) nothing is substituted for "/" or
    /// ":" — a playlist name is not a filename, and Music accepts both.
    static func displayName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Playlist" : trimmed
    }

    // MARK: - Creating (MediaPlayer)

    /// A new playlist holding exactly `mediaItems`, in order.
    private static func create(named title: String, with mediaItems: [MPMediaItem],
                               filesSkipped: Int,
                               unmatched: [String]) async throws -> MusicPlaylistSaveResult {
        let metadata = MPMediaPlaylistCreationMetadata(name: title)
        metadata.authorDisplayName = "Pocket Tandas"
        // A FRESH uuid every time. getPlaylist(with:) is keyed by the uuid and
        // ignores the creation metadata when one already exists, so reusing a uuid
        // would hand back the old playlist and APPEND to it — and "Save as a New
        // Playlist" has to mean a new playlist.
        let playlist = try await makePlaylist(uuid: UUID(), metadata: metadata)
        try await append(mediaItems, to: playlist)
        await linkForLaterReplace(playlist, named: title)
        return MusicPlaylistSaveResult(name: title, replacedExisting: false,
                                       submitted: mediaItems.count,
                                       filesSkipped: filesSkipped, unmatched: unmatched)
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

    // MARK: - Replacing (MusicKit)

    /// Point an existing playlist of ours at the current queue. MusicKit is the
    /// only framework that can do this, so this is where the persistentID bridge
    /// is unavoidable — and where it can fail without a wrong track being written,
    /// because an unresolved entry is dropped rather than approximated.
    private static func replace(_ playlist: Playlist, named title: String,
                                with mediaItems: [MPMediaItem], filesSkipped: Int,
                                unmatched: [String]) async throws -> MusicPlaylistSaveResult {
        let resolved = await resolve(mediaItems)
        let songs = mediaItems.compactMap { resolved[$0.persistentID] }
        guard !songs.isEmpty else { throw MusicPlaylistSaveError.replaceUnavailable(title) }

        let updated = try await MusicKit.MusicLibrary.shared.edit(playlist, items: songs)
        PlaylistRegistry.remember(updated.id, as: title)

        var missed = unmatched
        var seen: Set<UInt64> = []
        for item in mediaItems where resolved[item.persistentID] == nil {
            if seen.insert(item.persistentID).inserted { missed.append(item.title ?? "Unknown") }
        }
        return MusicPlaylistSaveResult(name: title, replacedExisting: true,
                                       submitted: songs.count,
                                       filesSkipped: filesSkipped, unmatched: missed)
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

    // MARK: - The persistentID bridge (replace only)

    /// persistentID → Song for everything that could be matched. Misses are not an
    /// error: the ID assumption below is undocumented, and matching is only ever
    /// best-effort.
    private static func resolve(_ items: [MPMediaItem]) async -> [UInt64: Song] {
        var byID: [UInt64: MPMediaItem] = [:]
        for item in items where byID[item.persistentID] == nil { byID[item.persistentID] = item }

        var found: [UInt64: Song] = [:]
        found.reserveCapacity(byID.count)

        // Pass 1 — bulk, on the assumption that a local library song's MusicItemID
        // is its MPMediaItem.persistentID in decimal. Chunked because `memberOf`
        // becomes an IN-list with an unpublished ceiling, and a silently truncated
        // response would look exactly like a library miss.
        for chunk in Array(byID.keys).chunked(into: 200) {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, memberOf: chunk.map { MusicItemID(String($0)) })
            guard let songs = try? await request.response().items else { continue }
            for song in songs {
                guard let pid = UInt64(song.id.rawValue), let expected = byID[pid] else { continue }
                // The ID equivalence is an undocumented observation, so confirm
                // each hit against the library item it claims to be. If the two
                // frameworks ever turn out to use separate ID spaces, a numeric
                // collision would otherwise drop a SILENTLY WRONG track into the
                // set; this turns that into a pass-2 lookup, and at worst an
                // honest "not found".
                guard fold(song.title) == fold(expected.title ?? "") else { continue }
                found[pid] = song
            }
        }

        // Pass 2 — one title query per still-missing track. Sequential and slow
        // (a whole milonga's worth of requests if pass 1 matched nothing at all),
        // but this only runs behind an explicit Save that shows a progress state.
        for (pid, item) in byID where found[pid] == nil {
            if let song = await songMatching(item) { found[pid] = song }
        }
        return found
    }

    /// The library song that best matches one library item by title, disambiguated
    /// on artist then duration. Tango libraries are full of the same title recorded
    /// by different orquestas — and by the same orquesta in different years — so
    /// artist is the stronger signal and duration breaks the remaining ties.
    private static func songMatching(_ item: MPMediaItem) async -> Song? {
        guard let title = item.title else { return nil }
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.title, equalTo: title)
        guard let candidates = try? await request.response().items, !candidates.isEmpty else {
            return nil
        }
        if candidates.count == 1 { return candidates.first }

        let artist = item.artist.map(fold)
        let sameArtist = candidates.filter { artist == nil || fold($0.artistName) == artist }
        let pool = sameArtist.isEmpty ? Array(candidates) : sameArtist
        let duration = item.playbackDuration
        return pool.min {
            abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration)
        }
    }

    /// The same leniency RemoteTrackResolver's metadata index uses, so "Biagi" and
    /// "BIAGI", "Fresedo" and "Fresédo" match.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Playlists we own

    /// MediaPlayer makes the playlist but only MusicKit can later replace its
    /// contents, so the MusicKit id of a playlist we just created is recorded here
    /// against its name. Both attempts have to PROVE the playlist is ours before
    /// anything is stored — replacing a playlist the user built by hand in Music
    /// would be unforgivable:
    ///
    ///  1. The persistentID bridge, confirmed against the name.
    ///  2. Failing that, a name query, trusted only when it returns exactly ONE
    ///     playlist. We created this one a moment ago, so it is in the library; a
    ///     playlist the user already had under the same name would make the count
    ///     two and nothing is stored rather than guessing which is ours.
    ///
    /// Storing nothing is a safe outcome, not a failure: the next save under this
    /// name just creates another playlist instead of offering to replace.
    private static func linkForLaterReplace(_ created: MPMediaPlaylist, named title: String) async {
        // Whatever this establishes REPLACES any earlier link for the name: after
        // a create, the registry names the playlist the user just made, or — when
        // neither attempt can prove ownership — nothing at all. Leaving the old
        // link in place would aim the next Replace at the previous playlist.
        PlaylistRegistry.forget(title)
        guard await authorizeMusicKit() else { return }

        if let bridged = await libraryPlaylist(id: MusicItemID(String(created.persistentID))),
           fold(bridged.name) == fold(title) {
            PlaylistRegistry.remember(bridged.id, as: title)
            return
        }
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.name, equalTo: title)
        guard let response = try? await request.response(),
              response.items.count == 1, let only = response.items.first else { return }
        PlaylistRegistry.remember(only.id, as: title)
    }

    /// MusicKit keeps its own authorization even though it rides the same Media &
    /// Apple Music grant MediaLibraryImporter has already asked for, and every
    /// MusicLibraryRequest here fails closed without it — which would quietly
    /// disable replacing rather than report anything. Free once the grant exists.
    private static func authorizeMusicKit() async -> Bool {
        await MusicAuthorization.request() == .authorized
    }

    private static func libraryPlaylist(id: MusicItemID) async -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: id)
        return try? await request.response().items.first
    }

    /// Names are the user-facing handle, MusicItemIDs are what edit() needs, so the
    /// map is kept across launches.
    private enum PlaylistRegistry {
        private static let key = "musicLibraryPlaylistIDsByName"

        static func id(for name: String) -> MusicItemID? {
            let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
            return stored?[name].map { MusicItemID($0) }
        }

        static func remember(_ id: MusicItemID, as name: String) {
            var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            stored[name] = id.rawValue
            UserDefaults.standard.set(stored, forKey: key)
        }

        static func forget(_ name: String) {
            guard var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
            else { return }
            stored[name] = nil
            UserDefaults.standard.set(stored, forKey: key)
        }
    }

    /// The live playlist we previously created under `name`, or nil if we never
    /// made one, never managed to link one, or the user has since deleted it (in
    /// which case the stale entry is dropped, so the next save creates cleanly
    /// instead of retrying a dead id).
    private static func ownedPlaylist(named name: String) async -> Playlist? {
        guard let id = PlaylistRegistry.id(for: name) else { return nil }
        guard await authorizeMusicKit() else { return nil }
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: id)
        // A thrown request is a transient failure — keep the link and let the save
        // fall through to creating a playlist. An EMPTY result is the playlist
        // genuinely being gone, so drop the stale id.
        guard let response = try? await request.response() else { return nil }
        guard let playlist = response.items.first else {
            PlaylistRegistry.forget(name)
            return nil
        }
        return playlist
    }
}

private extension Array {
    /// Fixed-size batches, in order.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
