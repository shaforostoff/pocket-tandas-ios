// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PreListenPlayer.swift
//  Pocket Tandas
//
//  "Prelistening": auditioning a browser audio file without disturbing the DJ
//  play queue. It owns a small AVAudioEngine of its own (a single player node →
//  downmix → pan → output) so the cue can be routed to its own output:
//
//    .off              plays to the shared route; Explore-only, idle-gated so it
//                      never overlaps the queue.
//    .stereoSplitTest  downmixed to mono and panned hard RIGHT — the 2-channel
//                      stand-in for cueing (queue holds the LEFT channel).
//    .fourChannel      stereo cue mapped to output channels 3+4, playing
//                      concurrently with the queue on 1+2 (DJ cueing).
//
//  When a track finishes it advances to the next file in the browser's *current*
//  arrangement (the view keeps `listing`/`listingFolder` in sync); if the user
//  has navigated away by then, it just stops. Completion fires on an engine
//  thread, so it hops to main, and is matched by a per-schedule token so a
//  stop/replace can't trigger a stale advance (see observable-not-mainactor).
//

import Foundation
import AVFoundation
import Observation

@Observable
final class PreListenPlayer {
    /// The audio file currently being auditioned, or nil when stopped. Drives the
    /// browser's stop button, the now-playing row highlight, and scroll-to-visible.
    private(set) var currentURL: URL?

    /// Bumped each time playback rolls over to the next track on its own — never on
    /// a user tap. The browser scrolls the new track into view on auto-advance, but
    /// leaves the list alone when the user taps a row (which is already on screen).
    private(set) var autoAdvanceCount = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    /// downmix collapses stereo→mono for the L/R test; pan places the cue on its
    /// channel. A stereo passthrough otherwise. See `applyRouting`.
    @ObservationIgnored private let downmix = AVAudioMixerNode()
    @ObservationIgnored private let pan = AVAudioMixerNode()
    @ObservationIgnored private var playerFormat: AVAudioFormat?

    /// Per-schedule token; only the active schedule's completion may advance.
    @ObservationIgnored private var scheduleSeq = 0
    @ObservationIgnored private var activeScheduleID = 0

    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let routing: AudioRouting

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

    init(audioSession: AudioSessionController, routing: AudioRouting) {
        self.audioSession = audioSession
        self.routing = routing
        configureGraph()
    }

    private func configureGraph() {
        engine.attach(player)
        engine.attach(downmix)
        engine.attach(pan)
        // player → downmix is wired per-file in `play` (the format varies);
        // downmix → pan → output is set by the routing.
        applyRouting()
        engine.prepare()
    }

    /// (Re)wire the cue's output for the active routing mode. Called from the
    /// launcher before a mode is entered (cue idle).
    ///
    ///  - `.off` / `.fourChannel`: stereo passthrough. 4-channel maps the stereo
    ///    cue onto hardware channels 3+4 (unverified on hardware — see
    ///    AudioSessionController.configure(for:)).
    ///  - `.stereoSplitTest`: downmix to mono and pan hard RIGHT.
    func applyRouting() {
        let std = engine.outputNode.outputFormat(forBus: 0)
        // Re-wire only downmix's *output* edge, then re-assert pan → output, so the
        // cue's path to the hardware is never left dangling (see PlaybackEngine).
        engine.disconnectNodeOutput(downmix)
        switch routing.mode {
        case .off, .fourChannel:
            engine.connect(downmix, to: pan, format: std)
            downmix.pan = 0
        case .stereoSplitTest:
            let mono = AVAudioFormat(standardFormatWithSampleRate: std.sampleRate, channels: 1) ?? std
            engine.connect(downmix, to: pan, format: mono)
            downmix.pan = 1                // mono cue → right channel only
        }
        engine.connect(pan, to: engine.outputNode, format: std)
        engine.outputNode.auAudioUnit.channelMap = (routing.mode == .fourChannel)
            ? [-1, -1, 0, 1].map { NSNumber(value: $0) }   // stereo cue → hardware ch 3+4
            : nil
    }

    /// Start (or restart, from the top) auditioning `url`, tapped while browsing
    /// `folder`. Replaces any track already prelistening.
    func play(_ url: URL, in folder: URL?) {
        audioSession.activate()
        guard let file = try? AVAudioFile(forReading: url) else {
            ptLog("prelisten FAILED to open \(url.lastPathComponent)")
            stop()
            return
        }
        connectPlayerIfNeeded(format: file.processingFormat)
        ensureRunning()
        player.stop()
        scheduleSeq += 1
        let scheduleID = scheduleSeq
        activeScheduleID = scheduleID
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.handleScheduleEnded(scheduleID) }
        }
        player.play()
        contextFolder = folder
        currentURL = url
        ptLog("prelisten play \(url.lastPathComponent) in \(folder?.lastPathComponent ?? "nil") sid=\(scheduleID)")
    }

    /// Stop auditioning (user Stop, finished with nowhere to advance, queue
    /// playback taking over in Explore, or leaving the screen).
    func stop() {
        guard isPlaying else { return }
        ptLog("prelisten stop")
        player.stop()
        activeScheduleID = 0          // 0 never matches a real token (they start at 1)
        currentURL = nil
        contextFolder = nil
    }

    /// Browser → player: the audio files now shown (display order) and the place
    /// they belong to. Cheap; called whenever the arrangement or folder changes.
    func updateListing(_ urls: [URL], folder: URL?) {
        listing = urls
        listingFolder = folder
    }

    // MARK: - Internals

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { ptLog("prelisten engine start failed: \(error)") }
    }

    private func connectPlayerIfNeeded(format: AVAudioFormat) {
        if let existing = playerFormat, existing == format { return }
        engine.connect(player, to: downmix, format: format)
        playerFormat = format
    }

    /// Called on main when a scheduled file finishes. Only the active schedule's
    /// completion advances; stale tokens (after stop/replace) are ignored.
    private func handleScheduleEnded(_ scheduleID: Int) {
        guard scheduleID == activeScheduleID else { return }
        advanceAfterFinish()
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
