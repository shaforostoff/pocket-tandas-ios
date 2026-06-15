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
//  The crux requirement — a queue edit made seconds before the current track
//  ends must be honoured — is satisfied by re-reading `queue.item(after:)` at the
//  transition moment (in `advance()`), never caching the "next" decision.
//
//  Completion handlers fire on an engine thread, so every handler hops to the
//  main thread before touching state or the queue (this class is plain
//  @Observable, not @MainActor — see the observable-not-mainactor note).
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
    @ObservationIgnored private var formats: [ObjectIdentifier: AVAudioFormat] = [:]
    @ObservationIgnored private let fader = FadeController()
    @ObservationIgnored private let audioSession: AudioSessionController
    @ObservationIgnored private let queue: PlayQueue

    /// Elapsed playback time of the active track (best effort, for Now Playing).
    var currentElapsed: TimeInterval {
        guard let nodeTime = activePlayer.lastRenderTime,
              let playerTime = activePlayer.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    init(audioSession: AudioSessionController, queue: PlayQueue) {
        self.audioSession = audioSession
        self.queue = queue
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
        _ = engine.mainMixerNode   // instantiate mixer + its output connection
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
        preloadedItemID = nil
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
        guard schedule(item, on: activePlayer, startNow: true) else { return }
        currentItem = item
        currentDuration = duration(of: item.url)
        setState(.playing(item.id))
        preloadNext(after: item.id)
    }

    @discardableResult
    private func schedule(_ item: QueueItem, on player: AVAudioPlayerNode, startNow: Bool) -> Bool {
        guard let file = try? AVAudioFile(forReading: item.url) else {
            print("[Engine] could not open \(item.filename)")
            return false
        }
        connectIfNeeded(player, format: file.processingFormat)
        player.stop()
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.handleTrackEnded(item.id) }
        }
        if startNow { player.play() }
        return true
    }

    private func preloadNext(after id: UUID) {
        guard let next = queue.item(after: id) else {
            preloadedItemID = nil
            return
        }
        preloadedItemID = schedule(next, on: standbyPlayer, startNow: false) ? next.id : nil
    }

    private func handleTrackEnded(_ endedID: UUID) {
        ptLog("trackEnded ended=\(endedID.uuidString.prefix(4)) state=\(state.debugLabel)")
        guard state.currentItemID == endedID else { return }   // ignore stale callbacks
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
            guard schedule(next, on: standbyPlayer, startNow: false) else {
                stop(); return
            }
            preloadedItemID = next.id
        }

        swap(&activePlayer, &standbyPlayer)   // standby (holding `next`) becomes active
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
        preloadedItemID = nil
        currentItem = nil
        currentDuration = 0
        engine.mainMixerNode.outputVolume = normalVolume
        setState(.idle)
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
