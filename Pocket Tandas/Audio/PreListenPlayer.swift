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

@Observable
final class PreListenPlayer: NSObject, AVAudioPlayerDelegate {
    /// The audio file currently being auditioned, or nil when stopped. Drives the
    /// browser's stop button, the now-playing row highlight, and scroll-to-visible.
    private(set) var currentURL: URL?

    /// Bumped each time playback rolls over to the next track on its own — never on
    /// a user tap. The browser scrolls the new track into view on auto-advance, but
    /// leaves the list alone when the user taps a row (which is already on screen).
    private(set) var autoAdvanceCount = 0

    /// File auditions use AVAudioPlayer; Music-library items use AVPlayer (which can
    /// open `ipod-library://` URLs, unlike AVAudioPlayer). At most one is live.
    @ObservationIgnored private var filePlayer: AVAudioPlayer?
    @ObservationIgnored private var mediaPlayer: AVPlayer?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private let audioSession: AudioSessionController

    /// The audio files of the place the browser is *currently* showing, in display
    /// order, plus the folder/playlist they belong to. Kept in sync by the browser
    /// so a finished track advances within the live (sorted/filtered) arrangement.
    @ObservationIgnored private var listing: [URL] = []
    @ObservationIgnored private var listingFolder: URL?

    /// The folder/playlist the current track was started from. Compared against
    /// `listingFolder` on finish: equal ⇒ still here, advance; differ ⇒ user moved
    /// away, stop.
    @ObservationIgnored private var contextFolder: URL?

    var isPlaying: Bool { currentURL != nil }

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        super.init()
    }

    /// Start (or restart, from the top) auditioning `url`, tapped while browsing
    /// `folder`. Replaces any track already prelistening. A file plays through
    /// AVAudioPlayer; a Music-library `ipod-library://` URL plays through AVPlayer.
    func play(_ url: URL, in folder: URL?) {
        teardownPlayers()
        audioSession.activate()
        if url.scheme == "ipod-library" {
            let item = AVPlayerItem(url: url)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                self?.advanceAfterFinish()
            }
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.play()
            mediaPlayer = newPlayer
        } else {
            guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
                ptLog("prelisten FAILED to open \(url.lastPathComponent)")
                currentURL = nil
                contextFolder = nil
                return
            }
            newPlayer.delegate = self
            newPlayer.play()
            filePlayer = newPlayer
        }
        contextFolder = folder
        currentURL = url
        ptLog("prelisten play \(url.lastPathComponent) in \(folder?.lastPathComponent ?? "nil")")
    }

    /// Stop auditioning (user Stop, finished with nowhere to advance, queue
    /// playback taking over, or leaving the screen). The shared audio session is
    /// left active so the queue engine can take over without a gap.
    func stop() {
        guard isPlaying else { return }
        ptLog("prelisten stop")
        teardownPlayers()
        currentURL = nil
        contextFolder = nil
    }

    /// Tear down whichever player is live, plus the AVPlayer end-of-item observer.
    private func teardownPlayers() {
        filePlayer?.stop()
        filePlayer = nil
        mediaPlayer?.pause()
        mediaPlayer = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Browser → player: the audio files now shown (display order) and the place
    /// they belong to. Cheap; called whenever the arrangement or folder changes.
    func updateListing(_ urls: [URL], folder: URL?) {
        listing = urls
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
        guard let finished = currentURL else { return }
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
