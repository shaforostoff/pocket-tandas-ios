// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteWireTypes.swift
//  Pocket Tandas
//
//  Value types exchanged between two phones in Remote Send / Remote Receive
//  modes. The receiver pre-resolves display fields (title/artist/detail) from its
//  own metadata cache so the sender can render the mirror with no metadata of its
//  own. Heavy `RemoteSnapshot` (structural change) is kept separate from the
//  lightweight `RemoteProgress` (timer ticks) so the live countdown doesn't
//  reserialize the whole queue. A monotonic `seq` lets the sender drop stale or
//  out-of-order messages.
//

import Foundation

/// Compact stand-in for a row's identity on the wire.
///
/// The receiver's QueueItem.id is a UUID, which JSON writes as 36 characters of
/// hex — and being random, it is the one thing zlib cannot shrink. In a hundred-row
/// queue those UUIDs were most of every snapshot and the whole of every command. A
/// small integer, assigned by the receiver and mapped back the moment a command
/// arrives, says the same thing in two or three characters: a text-less hundred-row
/// snapshot goes from 2580 compressed bytes to 376.
///
/// Handles are meaningful only to the receiver that issued them. It hands out a
/// fresh one per queue item and forgets it when the item leaves, so a command
/// naming a handle it no longer knows is simply ignored — which is what should
/// happen to a command aimed at a row that has since been removed.
typealias RowHandle = Int

/// One queue entry as seen over the wire. `id` is the receiver's handle for the row
/// — commands address rows by this identity, never by index.
///
/// The display text is sent ONCE PER CONNECTION per row: the receiver remembers
/// what it has told this sender about each id, and thereafter sends the row with
/// the text fields omitted (Codable drops nil keys, so a repeat row is ~60 bytes
/// instead of ~200). Text reappears whenever it is genuinely new — a freshly added
/// track, or a row whose metadata scan has since filled in a real title. The
/// sender merges nil fields against its own mirror; if it ever meets an id it has
/// no text for it asks for a full resync rather than showing a blank row.
struct RemoteQueueItem: Codable, Identifiable, Hashable {
    let id: RowHandle
    let title: String?
    let artist: String?
    let detail: String?      // right-aligned line: BPM · Genre · Date

    /// True when this row carries its display text (a new or changed row).
    var hasText: Bool { title != nil }
}

/// Playback state on its own, sent whenever the engine changes without the queue
/// changing — a track transition, Stop, Resume, pause. Keeping it out of
/// RemoteSnapshot is what stops every song change retransmitting the whole queue.
struct RemotePlaybackUpdate: Codable, Hashable {
    var playback: RemotePlaybackState
    var seq: UInt64
}

/// Mirror of PlaybackState for the wire (engine internals omitted). Carries the
/// current track's `duration`, which is constant for as long as that track is
/// current and so has no business riding along on every position update — this
/// message is already sent whenever the current track can change.
///
/// Version-tolerant: every field decodes to its default when the key is absent, so
/// a peer on an older build (which sent no duration) still decodes.
struct RemotePlaybackState: Codable, Hashable {
    enum Kind: String, Codable { case idle, playing, fadingOut, paused }
    var kind: Kind = .idle
    var currentItemID: RowHandle?
    var duration: TimeInterval = 0

    var isPlaying: Bool { kind == .playing }
    var isFadingOut: Bool { kind == .fadingOut }
    var isPaused: Bool { kind == .paused }

    init(kind: Kind = .idle, currentItemID: RowHandle? = nil, duration: TimeInterval = 0) {
        self.kind = kind
        self.currentItemID = currentItemID
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .idle
        currentItemID = try c.decodeIfPresent(RowHandle.self, forKey: .currentItemID)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
    }
}

/// Position of the current track — the one message a playing link sends over and
/// over, so it is kept to almost nothing. `itemID` and `duration` used to travel
/// with it and now live in RemotePlaybackState, which already covers every moment
/// either could change; what remains is ~44 bytes against the old 133.
///
/// It is also sent rarely: the sender runs the countdown from its own clock
/// between updates (see RemoteQueue.elapsed), so these arrive on a transition and
/// every ten seconds thereafter to pull drift back — not once a second.
struct RemoteProgress: Codable, Hashable {
    var elapsed: TimeInterval = 0
    var seq: UInt64 = 0

    init(elapsed: TimeInterval = 0, seq: UInt64 = 0) {
        self.elapsed = elapsed
        self.seq = seq
    }

    /// Tolerant of the extra keys an older receiver still sends.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
    }
}

/// Full authoritative state of the receiver's queue + playback, sent on any
/// structural change. There is only ever one anchor, so it rides in the header
/// rather than as a flag on every row — which also means moving it changes one
/// small field instead of rewriting the whole list.
struct RemoteSnapshot: Codable, Hashable {
    var items: [RemoteQueueItem]
    var anchor: RowHandle?
    var playback: RemotePlaybackState
    var seq: UInt64
}

/// What changed since the snapshot the sender is holding, for when saying that is
/// smaller than restating the queue. With rows already named by a compact handle, a
/// full snapshot is cheap — but a delta for the common edits (add one track, remove
/// one, drag one) is a few tens of bytes against a few hundred.
///
/// `baseSeq` is the seq the sender must currently hold. Anything else means the two
/// disagree about what is being edited, and the sender asks for a full snapshot
/// instead of guessing. `count` is a final check that applying the script produced
/// the list the receiver meant — cheap insurance on a stateful protocol, where a
/// silent divergence would otherwise persist until the next reconnect.
struct RemoteQueueDelta: Codable, Hashable {
    /// A row taking its place at `at` in the final list. Carries display text only
    /// when the sender can't already know it (a new row, or one whose metadata scan
    /// has just replaced a filename with a real title).
    struct Insertion: Codable, Hashable {
        var at: Int
        var item: RemoteQueueItem
    }

    var baseSeq: UInt64
    var seq: UInt64
    var removed: [RowHandle]
    var inserted: [Insertion]
    var anchor: RowHandle?
    var playback: RemotePlaybackState
    var count: Int
}

/// Turns "what the sender has" into "what the receiver has" as removals plus
/// insertions.
///
/// A greedy pass keeps the longest run of rows that already line up, in order;
/// everything else in the new list becomes an insertion at its final index, and
/// everything from the old list that wasn't kept becomes a removal. A row that
/// merely moved therefore appears in both — removed from where it was, re-inserted
/// where it now belongs — which is what makes a drag cost two small numbers.
///
/// Applying removals first and then insertions in ascending index order reproduces
/// the new list exactly: each insertion lands in a list whose earlier positions are
/// already final.
///
/// Rows carrying text are deliberately excluded from the keepable set. Display text
/// crosses the wire once per row per connection, so a row whose title has just been
/// filled in has no other way to reach the sender than by being re-inserted.
enum QueueEditScript {
    static func make(from old: [RowHandle], to new: [RemoteQueueItem])
        -> (removed: [RowHandle], inserted: [RemoteQueueDelta.Insertion]) {
        let surviving = Set(new.map(\.id))
        let resend = Set(new.lazy.filter(\.hasText).map(\.id))
        let base = old.filter { surviving.contains($0) && !resend.contains($0) }

        var inserted: [RemoteQueueDelta.Insertion] = []
        var kept = Set<RowHandle>()
        var next = 0
        for (index, item) in new.enumerated() {
            if next < base.count, base[next] == item.id {
                kept.insert(item.id)
                next += 1
            } else {
                inserted.append(.init(at: index, item: item))
            }
        }
        return (old.filter { !kept.contains($0) }, inserted)
    }
}

/// The receiver's audio-chain settings — EQ, master volume, and the two disc
/// restoration filters — broadcast to the sender on connect and on every change,
/// so the Remote Control screen's EQ, Volume and Restoration panels show what the
/// speakers are actually doing. `seq` shares the coordinator's counter, so stale
/// updates can be dropped.
///
/// The restoration half also carries what the receiver's hum detector has found
/// (`dehumLines`) and how far its per-track background analysis has got
/// (`scoutPhase`), because those are read-only diagnostics with nowhere else to
/// travel. Neither is chatty: the receiver only republishes a line once it has
/// moved further than the panel prints, so a settled record broadcasts nothing.
///
/// Version-tolerant like TrackAddRequest: every field has a default and decoding
/// tolerates a missing key, so a peer running an older/newer build still decodes —
/// which is what lets a sender on this build talk to a receiver that has never
/// heard of restoration, and simply show the filters switched off.
struct RemoteAudioSettings: Codable, Hashable {
    var eqEnabled: Bool = true
    var bands: [EQBand] = []
    var volume: Float = 1.0

    var declickEnabled: Bool = false
    var dehumEnabled: Bool = false
    var declick = DeclickSettings()
    var dehum = DehumSettings()
    var dehumLines: [DehumLine] = []
    var scoutPhase: RestorationScoutPhase = .idle
    /// Seconds of delay the receiver's declicker imposes at its current settings —
    /// derived from the receiver's own output sample rate, so it cannot be worked
    /// out from `declick` alone.
    var declickLatency: TimeInterval = 0

    var seq: UInt64 = 0

    init(eqEnabled: Bool = true, bands: [EQBand] = [], volume: Float = 1.0,
         declickEnabled: Bool = false, dehumEnabled: Bool = false,
         declick: DeclickSettings = DeclickSettings(), dehum: DehumSettings = DehumSettings(),
         dehumLines: [DehumLine] = [], scoutPhase: RestorationScoutPhase = .idle,
         declickLatency: TimeInterval = 0, seq: UInt64 = 0) {
        self.eqEnabled = eqEnabled
        self.bands = bands
        self.volume = volume
        self.declickEnabled = declickEnabled
        self.dehumEnabled = dehumEnabled
        self.declick = declick
        self.dehum = dehum
        self.dehumLines = dehumLines
        self.scoutPhase = scoutPhase
        self.declickLatency = declickLatency
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? true
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        declickEnabled = try c.decodeIfPresent(Bool.self, forKey: .declickEnabled) ?? false
        dehumEnabled = try c.decodeIfPresent(Bool.self, forKey: .dehumEnabled) ?? false
        declick = try c.decodeIfPresent(DeclickSettings.self, forKey: .declick) ?? DeclickSettings()
        dehum = try c.decodeIfPresent(DehumSettings.self, forKey: .dehum) ?? DehumSettings()
        dehumLines = try c.decodeIfPresent([DehumLine].self, forKey: .dehumLines) ?? []
        scoutPhase = try c.decodeIfPresent(RestorationScoutPhase.self, forKey: .scoutPhase) ?? .idle
        declickLatency = try c.decodeIfPresent(TimeInterval.self, forKey: .declickLatency) ?? 0
        seq = try c.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
    }
}

/// A request to add a track on the receiver. The receiver resolves it via
/// RemoteTrackResolver to either a local file (file source) or a track in its own
/// Music library (media source). For files, `relativePath` is the sender's
/// base-relative path and the metadata fields drive the fallback match. For media,
/// there is no shared path — `persistentID` differs per device — so matching is by
/// title/artist(/album/year/duration) against the receiver's synced library.
///
/// JSON/version-tolerant: every field is optional and `source` defaults to `.file`
/// (via the custom decoder) so a request from an older sender still decodes.
struct TrackAddRequest: Codable, Hashable {
    enum Source: String, Codable { case file, mediaLibrary }

    var source: Source = .file
    var relativePath: String?       // file source only
    var artist: String?
    var title: String?
    var dateText: String?
    var year: Int?
    var album: String?              // media: extra MPMediaQuery disambiguator
    var durationHint: TimeInterval? // media: tie-break near-equal-length matches

    init(source: Source = .file, relativePath: String? = nil, artist: String? = nil,
         title: String? = nil, dateText: String? = nil, year: Int? = nil,
         album: String? = nil, durationHint: TimeInterval? = nil) {
        self.source = source
        self.relativePath = relativePath
        self.artist = artist
        self.title = title
        self.dateText = dateText
        self.year = year
        self.album = album
        self.durationHint = durationHint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent ?? default — synthesized Codable would treat a missing
        // `source` key as an error, so apply the .file default explicitly.
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .file
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        dateText = try c.decodeIfPresent(String.self, forKey: .dateText)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationHint = try c.decodeIfPresent(TimeInterval.self, forKey: .durationHint)
    }
}
