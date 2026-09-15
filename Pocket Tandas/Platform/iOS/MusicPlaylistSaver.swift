// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicPlaylistSaver.swift
//  Pocket Tandas
//
//  Saves the play queue as a playlist in the device Music library — the MusicKit
//  counterpart of PlaylistWriter, and its exact mirror image. An .m3u8 can only
//  hold FILE tracks (PlaylistWriter skips media items); a library playlist can
//  only hold LIBRARY tracks (this skips file items). A queue mixing both
//  round-trips through neither, so each save reports what it left behind.
//
//  Why MusicKit rather than MediaPlayer's MPMediaPlaylist: MPMediaPlaylist is
//  append-only — no remove, no reorder, no replace — so re-saving an edited queue
//  under the same name could only pile more tracks onto the old playlist.
//  MusicKit.MusicLibrary.edit(_:items:) REPLACES the entries, which is what "save
//  this queue" means. The catch is that edit() only works on playlists this app
//  created, which is why PlaylistRegistry remembers the ones we made (see there).
//
//  Note the module-qualified MusicKit.MusicLibrary throughout: this project has
//  its own `enum MusicLibrary` (the MPMediaQuery wrapper next door), and inside
//  the module the bare name resolves to that one.
//
//  The bridge between the two frameworks is the awkward part. The queue holds
//  MPMediaItem.persistentIDs, because the Music browser is MPMediaQuery-based
//  (see MusicLibrary.swift), while createPlaylist wants MusicKit Songs — and
//  Apple documents no mapping between MPMediaItem.persistentID and MusicItemID.
//  In practice a local library song's MusicItemID is its persistentID in decimal,
//  so that is tried first as one bulk request; whatever it misses falls back to a
//  per-track title query scored on artist and duration. See resolve(_:).
//

import Foundation
import MusicKit

/// What a save actually did — every count here is something we know for a fact,
/// so the confirmation can be specific without overclaiming.
struct MusicPlaylistSaveResult {
    let name: String
    /// True when an existing app-created playlist had its contents replaced
    /// rather than a new playlist being created.
    let replacedExisting: Bool
    /// Library tracks handed to MusicKit, in queue order (duplicates included).
    let submitted: Int
    /// Queue entries that were folder files — a library playlist can't hold them.
    let filesSkipped: Int
    /// Distinct titles of library tracks neither resolution pass could match back
    /// to a MusicKit Song.
    let unmatched: [String]
}

enum MusicPlaylistSaveError: LocalizedError {
    case notAuthorized(MusicAuthorization.Status)
    case noLibraryTracks
    case nothingResolved

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
            return "None of the queue's Music tracks could be matched in your "
                 + "library. They may have been removed since they were added."
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
        let status = await MusicAuthorization.request()
        guard status == .authorized else { throw MusicPlaylistSaveError.notAuthorized(status) }

        let wanted = items.compactMap(Wanted.init(queueItem:))
        guard !wanted.isEmpty else { throw MusicPlaylistSaveError.noLibraryTracks }
        let filesSkipped = items.count - wanted.count

        let resolved = await resolve(wanted)
        // Map the ORDERED queue back through the lookup: order is the whole point
        // of a DJ set, and a repeat (the same cortina between every tanda) has to
        // come out as a repeat rather than being collapsed into one entry.
        let songs = wanted.compactMap { resolved[$0.persistentID] }
        guard !songs.isEmpty else { throw MusicPlaylistSaveError.nothingResolved }

        var unmatched: [String] = []
        var seen: Set<UInt64> = []
        for entry in wanted where resolved[entry.persistentID] == nil {
            if seen.insert(entry.persistentID).inserted { unmatched.append(entry.title) }
        }

        let title = displayName(from: name)
        if replacingExisting, let existing = await ownedPlaylist(named: title) {
            let updated = try await MusicKit.MusicLibrary.shared.edit(existing, items: songs)
            PlaylistRegistry.remember(updated.id, as: title)
            return MusicPlaylistSaveResult(name: title, replacedExisting: true,
                                           submitted: songs.count, filesSkipped: filesSkipped,
                                           unmatched: unmatched)
        }

        let created = try await MusicKit.MusicLibrary.shared.createPlaylist(
            name: title, authorDisplayName: "Pocket Tandas", items: songs)
        // "Save as a New Playlist" under a name we already own hands the name to
        // the new playlist: Music allows duplicate names, and the one the user
        // just made is the one they will mean next time.
        PlaylistRegistry.remember(created.id, as: title)
        return MusicPlaylistSaveResult(name: title, replacedExisting: false,
                                       submitted: songs.count, filesSkipped: filesSkipped,
                                       unmatched: unmatched)
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

    // MARK: - Resolution

    /// One queue media entry reduced to what matching needs. Title and artist come
    /// from the snapshot captured at enqueue (MediaRef itself carries only a
    /// display title), falling back to the ref when there is no snapshot.
    private struct Wanted {
        let persistentID: UInt64
        let title: String
        let artist: String?
        let duration: TimeInterval

        init?(queueItem item: QueueItem) {
            guard let ref = item.mediaRef else { return nil }
            persistentID = ref.persistentID
            title = item.mediaSnapshot?.title ?? ref.displayTitle
            artist = item.mediaSnapshot?.artist
            duration = ref.duration
        }
    }

    /// persistentID → Song for everything that could be matched. Misses are not an
    /// error: the ID assumption below is undocumented, and a track can also have
    /// been removed from the library since it was queued.
    private static func resolve(_ wanted: [Wanted]) async -> [UInt64: Song] {
        let byID = Dictionary(grouping: wanted, by: \.persistentID)
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
                guard let pid = UInt64(song.id.rawValue),
                      let expected = byID[pid]?.first else { continue }
                // The ID equivalence is an undocumented observation, so confirm
                // each hit against the title we queued. If the two frameworks ever
                // turn out to use separate ID spaces, a numeric collision would
                // otherwise drop a SILENTLY WRONG track into the set; this turns
                // that into a pass-2 lookup, and at worst an honest "not found".
                guard fold(song.title) == fold(expected.title) else { continue }
                found[pid] = song
            }
        }

        // Pass 2 — one title query per still-missing track. Sequential and slow
        // (a whole milonga's worth of requests if pass 1 matched nothing at all),
        // but this only runs behind an explicit Save that shows a progress state.
        for (pid, group) in byID where found[pid] == nil {
            guard let probe = group.first else { continue }
            if let song = await songMatching(probe) { found[pid] = song }
        }
        return found
    }

    /// The library song that best matches one queue entry by title, disambiguated
    /// on artist then duration. Tango libraries are full of the same title recorded
    /// by different orquestas — and by the same orquesta in different years — so
    /// artist is the stronger signal and duration breaks the remaining ties.
    private static func songMatching(_ wanted: Wanted) async -> Song? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.title, equalTo: wanted.title)
        guard let candidates = try? await request.response().items, !candidates.isEmpty else {
            return nil
        }
        if candidates.count == 1 { return candidates.first }

        let artist = wanted.artist.map(fold)
        let sameArtist = candidates.filter { artist == nil || fold($0.artistName) == artist }
        let pool = sameArtist.isEmpty ? Array(candidates) : sameArtist
        return pool.min {
            abs(($0.duration ?? 0) - wanted.duration) < abs(($1.duration ?? 0) - wanted.duration)
        }
    }

    /// The same leniency RemoteTrackResolver's metadata index uses, so "Biagi" and
    /// "BIAGI", "Fresedo" and "Fresédo" match.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Playlists we own

    /// MusicLibrary.edit(_:items:) only works on playlists created by this app, so
    /// re-saving a set under the same name has to find OUR playlist rather than
    /// any playlist with that name — replacing a playlist the user built by hand
    /// in Music would be unforgivable. Names are the user-facing handle, ids are
    /// what MusicKit needs, so the map is kept here across launches.
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
    /// made one or the user has since deleted it (in which case the stale entry is
    /// dropped, so the next save creates cleanly instead of retrying a dead id).
    private static func ownedPlaylist(named name: String) async -> Playlist? {
        guard let id = PlaylistRegistry.id(for: name) else { return nil }
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
