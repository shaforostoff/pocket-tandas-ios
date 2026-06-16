// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaybackEngine.swift
//  Pocket Tandas
//
//  The core audio engine: AVAudioEngine driving two AVAudioPlayerNodes (A/B)
//  into the main mixer. One node is active (audible), the other standby
//  (preloaded next) — roles swap on each transition for gapless hand-off.
//  The mixer's outputVolume is the single fade lever.
//
//  A queue edit made seconds before the current track ends is honoured by
//  re-reading `queue.item(after:)` at the transition moment (in `advance()`),
//  never caching the "next" decision.
//
//  Completions are identified by a per-schedule GENERATION TOKEN, not by item
//  id: the engine reacts only to the completion of the currently audible
//  schedule. This is essential because the SAME track can be scheduled on two
//  nodes at once (e.g. preloaded on standby AND tapped to play on active);
//  stopping the standby fires a stale `.dataPlayedBack` whose item id would
//  otherwise match the new current track and trigger a spurious advance.
//
//  Completion handlers fire on an engine thread, so each hops to the main
//  thread before touching state (this class is plain @Observable, not
//  @MainActor — see the observable-not-mainactor note).
//

import Foundation
import AVFoundation
import Observation

@Observable
final class PlaybackEngine {
    /// Single source of truth for what the engine is doing.
    private(set) var state: PlaybackState = .idle

    /// Called after every state change (used by NowPlayingController).
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored let normalVolume: Float = 1.0
    @ObservationIgnored let fadeOutDuration: TimeInterval = 10

    /// The item currently loaded, plus its duration — for Now Playing info.
    @ObservationIgnored private(set) var currentItem: QueueItem?
    @ObservationIgnored private(set) var currentDuration: TimeInterval = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let playerA = AVAudioPlayerNode()
    @ObservationIgnored private let playerB = AVAudioPlayerNode()
    @ObservationIgnored private var activePlayer: AVAudioPlayerNode
    @ObservationIgnored private var standbyPlayer: AVAudioPlayerNode
    @ObservationIgnored private var preloadedItemID: UUID?

    /// Monotonic schedule tokens. `activeScheduleID` is the token of the audible
    /// schedule; only its completion may advance. `preloadedScheduleID` is the
    /// token of the standby's preloaded schedule (becomes active on swap).
    @ObservationIgnored private var scheduleSeq = 0
    @ObservationIgnored private var activeScheduleID = 0
    @ObservationIgnored private var preloadedScheduleID = 0

    @ObservationIgnored private var formats: [ObjectIdentifier: AVAudioFormat] = [:]
    @ObservationIgnored private let fader = FadeController()
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let queue: PlayQueue
    @ObservationIgnored private let metadata: MetadataService
    @ObservationIgnored private let equalizer: Equalizer

    /// Elapsed playback time of the active track (best effort, for Now Playing).
    var currentElapsed: TimeInterval {
        guard let nodeTime = activePlayer.lastRenderTime,
              let playerTime = activePlayer.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    init(audioSession: AudioSessionController, queue: PlayQueue, metadata: MetadataService, equalizer: Equalizer) {
        self.audioSession = audioSession
        self.queue = queue
        self.metadata = metadata
        self.equalizer = equalizer
        self.activePlayer = playerA
        self.standbyPlayer = playerB
        configureGraph()
        observeConfigurationChange()
        wireSessionEvents()
    }

    // MARK: - Setup

    private func configureGraph() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(equalizer.node)
        // Insert the master EQ between the mixer (our fade lever) and the output:
        //   players → mainMixerNode → eq → outputNode
        // Both players already sum at the mixer, so a single EQ on the mixer's
        // output colours everything. Connecting the mixer's output here replaces
        // the implicit mainMixerNode → outputNode connection.
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        engine.connect(mixer, to: equalizer.node, format: format)
        engine.connect(equalizer.node, to: engine.outputNode, format: format)
        engine.prepare()
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { print("[Engine] start failed: \(error)") }
    }

    private func observeConfigurationChange() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func wireSessionEvents() {
        audioSession.onInterruptionBegan = { [weak self] in self?.handleInterruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] resume in self?.handleInterruptionEnded(shouldResume: resume) }
    }

    // MARK: - Public control

    /// Tap-to-play from the queue. While already playing, a tap is rejected (the
    /// user must Stop first) — EXCEPT while a fade-out is in progress, when the
    /// tapped track starts immediately and the fade is cancelled.
    func requestPlay(_ item: QueueItem) {
        ptLog("requestPlay tapped=\(item.filename)#\(item.id.uuidString.prefix(4)) state=\(state.debugLabel) | queue: \(queue.debugOrder)")
        switch state {
        case .idle:
            startPlaying(item)
        case .fadingOut:
            fader.cancel()
            engine.mainMixerNode.outputVolume = normalVolume
            startPlaying(item)
        case .playing, .paused:
            break
        }
    }

    /// Begin the 10-second fade-out. The control turns into Resume while this
    /// runs; the actual stop is deferred to the ramp's completion so Resume can
    /// cancel it.
    func stopWithFade() {
        guard case .playing(let id) = state else { return }
        ptLog("stopWithFade current=\(id.uuidString.prefix(4))")
        setState(.fadingOut(id))
        fader.ramp(from: engine.mainMixerNode.outputVolume,
                   to: 0,
                   duration: fadeOutDuration,
                   apply: { [weak self] v in self?.engine.mainMixerNode.outputVolume = v },
                   completion: { [weak self] in self?.finishFadeStop() })
    }

    /// Cancel an in-progress fade-out and ramp the volume back up, continuing
    /// playback. Guards against accidental Stop presses.
    func resumeFromFade() {
        guard case .fadingOut(let id) = state else { return }
        ptLog("resumeFromFade current=\(id.uuidString.prefix(4))")
        fader.cancel()
        setState(.playing(id))
        fader.ramp(from: engine.mainMixerNode.outputVolume,
                   to: normalVolume,
                   duration: 0.3,
                   apply: { [weak self] v in self?.engine.mainMixerNode.outputVolume = v },
                   completion: {})
    }

    /// Instant stop (queue exhausted, or the deferred end of a fade-out).
    func stop() {
        ptLog("stop → idle")
        fader.cancel()
        activePlayer.stop()
        standbyPlayer.stop()
        clearSchedules()
        currentItem = nil
        currentDuration = 0
        engine.mainMixerNode.outputVolume = normalVolume
        setState(.idle)
    }

    /// Pause/resume (remote commands + interruptions). Not a primary UI feature.
    func pause() {
        guard case .playing(let id) = state else { return }
        activePlayer.pause()
        setState(.paused(id))
    }

    func resume() {
        guard case .paused(let id) = state else { return }
        audioSession.activate()
        ensureEngineRunning()
        activePlayer.play()
        setState(.playing(id))
    }

    /// Skip to the next queued track (remote "next" command).
    func skipToNext() {
        guard state.isPlaying else { return }
        advance()
    }

    // MARK: - Internal playback

    private func setState(_ newState: PlaybackState) {
        state = newState
        onStateChange?()
    }

    private func startPlaying(_ item: QueueItem) {
        ptLog("startPlaying \(item.filename)#\(item.id.uuidString.prefix(4))")
        audioSession.activate()
        ensureEngineRunning()
        engine.mainMixerNode.outputVolume = normalVolume
        guard let scheduleID = schedule(item, on: activePlayer, startNow: true) else { return }
        activeScheduleID = scheduleID
        currentItem = item
        currentDuration = duration(of: item.url)
        setState(.playing(item.id))
        preloadNext(after: item.id)
    }

    /// Schedules `item` on `player`. Returns the unique schedule token, or nil if
    /// the file couldn't be opened.
    private func schedule(_ item: QueueItem, on player: AVAudioPlayerNode, startNow: Bool) -> Int? {
        guard let file = try? AVAudioFile(forReading: item.url) else {
            ptLog("schedule FAILED to open \(item.filename)")
            return nil
        }
        scheduleSeq += 1
        let scheduleID = scheduleSeq
        connectIfNeeded(player, format: file.processingFormat)
        player.stop()
        // Per-track ReplayGain lives on the player node's own volume, so it rides
        // with the node through the active/standby swap and composes
        // multiplicatively with the mixer's fade lever. Set before play.
        let gain = trackGainScale(for: item)
        player.volume = gain
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.handleScheduleEnded(scheduleID) }
        }
        if startNow { player.play() }
        ptLog("schedule \(item.filename)#\(item.id.uuidString.prefix(4)) sid=\(scheduleID) startNow=\(startNow) gain=\(gain)")
        return scheduleID
    }

    /// ReplayGain track gain → linear amplitude scale for a player node's volume,
    /// looked up live from the metadata cache. Defaults to unity (1.0) when the
    /// track has no gain data (e.g. not yet scanned). Negative dB attenuates;
    /// positive dB boosts — the node accepts > 1.0 (its only clamp is at 0).
    private func trackGainScale(for item: QueueItem) -> Float {
        guard let db = metadata.snapshot(forKey: item.trackKey)?.trackGainDB else { return 1.0 }
        return Float(pow(10.0, db / 20.0))
    }

    private func preloadNext(after id: UUID) {
        guard let next = queue.item(after: id) else {
            preloadedItemID = nil
            preloadedScheduleID = 0
            return
        }
        if let scheduleID = schedule(next, on: standbyPlayer, startNow: false) {
            preloadedItemID = next.id
            preloadedScheduleID = scheduleID
        } else {
            preloadedItemID = nil
            preloadedScheduleID = 0
        }
    }

    /// Called (on main) when a scheduled file finishes. Only the audible
    /// schedule may advance; stale tokens (stopped/replaced schedules) are ignored.
    private func handleScheduleEnded(_ scheduleID: Int) {
        ptLog("scheduleEnded sid=\(scheduleID) active=\(activeScheduleID) state=\(state.debugLabel)")
        guard scheduleID == activeScheduleID else {
            ptLog("  ignored (stale schedule)")
            return
        }
        switch state {
        case .playing:
            advance()
        case .fadingOut:
            stop()   // finished on its own before the fade completed
        case .idle, .paused:
            break
        }
    }

    /// The live transition: re-read the queue NOW to decide what plays next.
    private func advance() {
        guard let currentID = state.currentItemID else { return }
        ensureEngineRunning()
        activePlayer.stop()

        guard let next = queue.item(after: currentID) else {
            ptLog("advance current=\(currentID.uuidString.prefix(4)) next=nil → stop | queue: \(queue.debugOrder)")
            stop()                       // queue exhausted
            return
        }
        ptLog("advance current=\(currentID.uuidString.prefix(4)) next=\(next.filename)#\(next.id.uuidString.prefix(4)) preloaded=\(preloadedItemID?.uuidString.prefix(4) ?? "nil") | queue: \(queue.debugOrder)")

        if preloadedItemID != next.id {
            guard let scheduleID = schedule(next, on: standbyPlayer, startNow: false) else {
                stop(); return
            }
            preloadedItemID = next.id
            preloadedScheduleID = scheduleID
        }

        swap(&activePlayer, &standbyPlayer)   // standby (holding `next`) becomes active
        activeScheduleID = preloadedScheduleID
        engine.mainMixerNode.outputVolume = normalVolume
        activePlayer.play()
        currentItem = next
        currentDuration = duration(of: next.url)
        setState(.playing(next.id))
        preloadNext(after: next.id)
    }

    private func finishFadeStop() {
        ptLog("fade complete → idle")
        activePlayer.stop()
        standbyPlayer.stop()
        clearSchedules()
        currentItem = nil
        currentDuration = 0
        engine.mainMixerNode.outputVolume = normalVolume
        setState(.idle)
    }

    private func clearSchedules() {
        preloadedItemID = nil
        activeScheduleID = 0      // 0 never matches a real token (tokens start at 1)
        preloadedScheduleID = 0
    }

    private func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    private func connectIfNeeded(_ player: AVAudioPlayerNode, format: AVAudioFormat) {
        let key = ObjectIdentifier(player)
        if let existing = formats[key], existing == format { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        formats[key] = format
    }

    // MARK: - Interruptions / route changes

    private func handleInterruptionBegan() {
        switch state {
        case .playing(let id):
            activePlayer.pause()
            setState(.paused(id))
        case .fadingOut:
            stop()
        default:
            break
        }
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard shouldResume, case .paused = state else { return }
        resume()
    }

    /// Fired on route changes (e.g. Bluetooth/USB connect-disconnect). The graph
    /// may have been reset; force reconnection and restart. Seamless mid-track
    /// recovery is best verified on a real device.
    private func handleConfigurationChange() {
        formats.removeAll()
        guard state.isPlaying || state.isFadingOut else { return }
        ensureEngineRunning()
        if !activePlayer.isPlaying { activePlayer.play() }
    }
}
