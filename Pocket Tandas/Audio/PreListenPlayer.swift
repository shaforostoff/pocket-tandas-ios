// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PreListenPlayer.swift
//  Pocket Tandas
//
//  Explore-mode "prelistening": tap an audio file in the browser to audition it
//  directly, without touching the DJ play queue. A deliberately simple
//  AVAudioPlayer (not the dual-node engine) — one file at a time, no fades, no
//  ReplayGain — that only runs while the play queue is idle.
//
//  When a track finishes it advances to the next file in the browser's *current*
//  arrangement: the view keeps `listing`/`listingFolder` in sync with what it
//  shows (live sort + filter), so the next pick honours those. If the user has
//  navigated to a different place by the time the track ends, playback just
//  stops — the file kept playing while away, but we don't auto-advance elsewhere.
//
//  Like the engine, the AVAudioPlayer delegate callback fires off the main
//  thread, so it hops to main before touching state (see observable-not-mainactor).
//

import Foundation
import AVFoundation
import Observation

/// What can be auditioned: a file on disk, or a Music-library track named by its
/// persistent id. The library case stays an id right up until playback starts —
/// resolving its `ipod-library://` asset URL is expensive, and the browser pushes
/// a whole listing here on every sort/filter change.
enum PreListenTrack: Hashable {
    case file(URL)
    case media(persistentID: UInt64)

    /// The disk URL, for the file browser's row highlight and scroll-to-visible.
    var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    /// Short label for diagnostic logging.
    var debugLabel: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .media(let pid): return "medialib:\(pid)"
        }
    }
}

@Observable
final class PreListenPlayer: NSObject, AVAudioPlayerDelegate {
    /// The track currently being auditioned, or nil when stopped. Drives the
    /// browser's stop button, the now-playing row highlight, and scroll-to-visible.
    private(set) var current: PreListenTrack?

    /// Bumped each time playback rolls over to the next track on its own — never on
    /// a user tap. The browser scrolls the new track into view on auto-advance, but
    /// leaves the list alone when the user taps a row (which is already on screen).
    private(set) var autoAdvanceCount = 0

    /// Called whenever the audition starts, changes track or stops — the hook the
    /// NowPlayingController republishes the lock screen from. (`current` is
    /// observable, but @Observable tracking only reaches SwiftUI view bodies.)
    @ObservationIgnored var onStateChange: (() -> Void)?

    /// File auditions use AVAudioPlayer; Music-library items use AVPlayer (which can
    /// open `ipod-library://` URLs, unlike AVAudioPlayer). At most one is live.
    @ObservationIgnored private var filePlayer: AVAudioPlayer?
    @ObservationIgnored private var mediaPlayer: AVPlayer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var mediaDuration: TimeInterval = 0

    /// Title/artist/genre of a library track being auditioned, captured from the
    /// MPMediaItem resolved at start — a file's details live in the metadata cache
    /// instead, but a library track has no file to scan. Read by
    /// NowPlayingController; nil while a file (or nothing) is auditioning.
    @ObservationIgnored private(set) var mediaMetadata: TrackMetadataSnapshot?
    @ObservationIgnored private let audioSession: AudioSessionController

    /// The audio tracks of the place the browser is *currently* showing, in display
    /// order, plus the folder/playlist they belong to. Kept in sync by the browser
    /// so a finished track advances within the live (sorted/filtered) arrangement.
    @ObservationIgnored private var listing: [PreListenTrack] = []
    @ObservationIgnored private var listingFolder: URL?

    /// The folder/playlist the current track was started from. Compared against
    /// `listingFolder` on finish: equal ⇒ still here, advance; differ ⇒ user moved
    /// away, stop.
    @ObservationIgnored private var contextFolder: URL?

    var isPlaying: Bool { current != nil }

    /// Length of the current audition, 0 when stopped. A library track's length
    /// comes from its MPMediaItem (captured at start — AVPlayer only learns the
    /// duration asynchronously); a file's from AVAudioPlayer.
    var currentDuration: TimeInterval {
        if let filePlayer { return filePlayer.duration }
        return mediaDuration
    }

    /// Playback position of the current audition, 0 when stopped.
    var currentElapsed: TimeInterval {
        if let filePlayer { return filePlayer.currentTime }
        guard let mediaPlayer else { return 0 }
        let time = mediaPlayer.currentTime().seconds
        return time.isFinite ? time : 0
    }

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        super.init()
    }

    /// Start (or restart, from the top) auditioning `track`, tapped while browsing
    /// `folder`. Replaces any track already prelistening. A file plays through
    /// AVAudioPlayer; a library track's asset URL is resolved here (the only point
    /// it is needed) and plays through AVPlayer, which can open `ipod-library://`.
    func play(_ track: PreListenTrack, in folder: URL?) {
        teardownPlayers()
        audioSession.activate(for: .prelisten)
        let started: Bool
        switch track {
        case .file(let url):
            started = startFile(url)
        case .media(let persistentID):
            started = startMedia(persistentID: persistentID)
        }
        guard started else {
            current = nil
            contextFolder = nil
            audioSession.release(.prelisten)
            onStateChange?()
            return
        }
        contextFolder = folder
        current = track
        ptLog("prelisten play \(track.debugLabel) in \(folder?.lastPathComponent ?? "nil")")
        onStateChange?()
    }

    private func startFile(_ url: URL) -> Bool {
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
            ptLog("prelisten FAILED to open \(url.lastPathComponent)")
            return false
        }
        newPlayer.delegate = self
        #if os(macOS)
        // The cue's whole purpose on a Mac: send it somewhere other than the room.
        // `currentDevice` takes a device UID (macOS 10.13+, no iOS counterpart) and
        // is set per player, so a change to the choice lands on the next audition
        // with no engine to rebuild. Nil means the system default.
        newPlayer.currentDevice = audioSession.cueDeviceUIDIfAttached
        #endif
        newPlayer.play()
        filePlayer = newPlayer
        return true
    }

    private func startMedia(persistentID: UInt64) -> Bool {
        #if os(iOS)
        guard let libraryItem = MusicLibrary.item(forPersistentID: persistentID),
              let url = libraryItem.assetURL else {
            ptLog("prelisten FAILED to resolve medialib:\(persistentID)")
            return false
        }
        mediaDuration = libraryItem.playbackDuration
        mediaMetadata = TrackMetadataSnapshot(mediaItem: libraryItem)
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.advanceAfterFinish()
        }
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.play()
        mediaPlayer = newPlayer
        return true
        #else
        // No Music library on macOS, so a queue can hold no media items to audition.
        return false
        #endif
    }

    /// Stop auditioning (user Stop, finished with nowhere to advance, queue
    /// playback taking over, or leaving the screen). Our claim on the shared audio
    /// session is dropped, but the release is deferred a runloop turn, so the queue
    /// engine taking over in the same turn still gets a gapless hand-off — and an
    /// app that stops auditioning and does nothing else stops being the system's
    /// Now Playing app instead of leaving an empty lock-screen transport behind.
    func stop() {
        guard isPlaying else { return }
        ptLog("prelisten stop")
        teardownPlayers()
        current = nil
        contextFolder = nil
        audioSession.release(.prelisten)
        onStateChange?()
    }

    /// Tear down whichever player is live, plus the AVPlayer end-of-item observer.
    private func teardownPlayers() {
        filePlayer?.stop()
        filePlayer = nil
        mediaPlayer?.pause()
        mediaPlayer = nil
        mediaDuration = 0
        mediaMetadata = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Browser → player: the audio tracks now shown (display order) and the place
    /// they belong to. Cheap; called whenever the arrangement or folder changes.
    func updateListing(_ tracks: [PreListenTrack], folder: URL?) {
        listing = tracks
        listingFolder = folder
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.advanceAfterFinish() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.advanceAfterFinish() }
    }

    /// Pick the next file in the current arrangement and play it — but only while
    /// the user is still viewing the place this track came from. Otherwise stop.
    private func advanceAfterFinish() {
        guard let finished = current else { return }
        guard listingFolder == contextFolder,
              let idx = listing.firstIndex(of: finished),
              idx + 1 < listing.count else {
            stop()
            return
        }
        play(listing[idx + 1], in: contextFolder)
        autoAdvanceCount += 1
    }
}
