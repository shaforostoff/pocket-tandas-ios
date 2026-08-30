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

    /// Called the instant queue playback (re)starts, before the track is made
    /// audible — so Explore-mode prelistening (a separate AVAudioPlayer) is torn
    /// down first and the two never overlap. See PreListenPlayer.
    @ObservationIgnored var onPlaybackStart: (() -> Void)?

    /// Master fader position, 0…1. Set from the Volume panel (locally or over the
    /// remote link) and persisted, so a level survives relaunches.
    static let masterVolumeKey = "playback.masterVolume"
    private(set) var masterVolume: Float = 1.0

    /// The mixer level that means "full, un-faded playback" — the fader position
    /// through the perceptual taper (see VolumeTaper). Fades ramp between it and 0.
    var normalVolume: Float { VolumeTaper.amplitude(for: masterVolume) }

    /// DJ-mode fade-out length (seconds). Configurable from the Launcher and
    /// persisted under `fadeOutDurationKey`; read live at each Stop so a change
    /// takes effect on the next fade. Explore mode stops instantly (see
    /// `stop()`) and ignores this entirely.
    static let fadeOutDurationKey = "dj.fadeOutDuration"
    static let fadeOutDurationRange: ClosedRange<TimeInterval> = 1...10
    static let defaultFadeOutDuration: TimeInterval = 10

    var fadeOutDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.fadeOutDurationKey)
        return Self.fadeOutDurationRange.contains(stored) ? stored : Self.defaultFadeOutDuration
    }

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

    /// Off-main decode for media-library items (AVAssetReader → a stream of short
    /// PCM chunks, see MediaTrackDecoder). `decodeToken` is bumped whenever a
    /// decode is started or cancelled, so a superseded decode's chunks (which
    /// captured an older token) are dropped rather than scheduled.
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "tandas.mediadecode", qos: .userInitiated)
    @ObservationIgnored private var decodeToken = 0
    @ObservationIgnored private var activeDecoder: MediaTrackDecoder?
    @ObservationIgnored private var mediaStream: MediaStream?

    /// Bookkeeping for the media track currently being streamed onto a deck. A
    /// media item arrives as several chunks scheduled back-to-back, so "the track
    /// ended" is: the decoder finished AND every chunk it handed over has played
    /// back. All fields are touched on the main thread only.
    private struct MediaStream {
        let token: Int
        let itemID: UUID
        /// Token of the schedule the first chunk opened (0 until then).
        var scheduleID = 0
        var scheduled = 0
        var played = 0
        var decodeFinished = false

        var isComplete: Bool { decodeFinished && scheduled > 0 && played == scheduled }
    }

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
        self.masterVolume = Self.persistedMasterVolume()
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
        mixer.outputVolume = normalVolume
        engine.prepare()
    }

    /// Stored master volume, or unity when nothing was ever set (`double(forKey:)`
    /// would read a missing key as 0 — silence).
    private static func persistedMasterVolume() -> Float {
        guard let stored = UserDefaults.standard.object(forKey: masterVolumeKey) as? Double else { return 1.0 }
        return Float(stored).clamped(to: 0...1)
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
    /// user must Stop/Pause first) — EXCEPT:
    ///  - while a fade-out is in progress, the tapped track starts immediately
    ///    and the fade is cancelled; and
    ///  - while paused, the tapped track (re)starts from the beginning, so even
    ///    the currently paused track can be restarted from the top.
    func requestPlay(_ item: QueueItem) {
        ptLog("requestPlay tapped=\(item.filename)#\(item.id.uuidString.prefix(4)) state=\(state.debugLabel) | queue: \(queue.debugOrder)")
        switch state {
        case .idle:
            startPlaying(item)
        case .fadingOut:
            fader.cancel()
            engine.mainMixerNode.outputVolume = normalVolume
            startPlaying(item)
        case .paused:
            startPlaying(item)
        case .playing:
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

    /// Set the master output level (0…1) and persist it. Applied to the mixer at
    /// once so a drag is audible live — except while a fade-out owns the lever, in
    /// which case the new level takes effect on the next play/resume.
    func setMasterVolume(_ value: Float) {
        let level = value.clamped(to: 0...1)
        guard level != masterVolume else { return }
        masterVolume = level
        UserDefaults.standard.set(Double(level), forKey: Self.masterVolumeKey)
        if !state.isFadingOut { engine.mainMixerNode.outputVolume = normalVolume }
    }

    /// Instant stop (queue exhausted, or the deferred end of a fade-out).
    func stop() {
        ptLog("stop → idle")
        cancelDecode()
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
        onPlaybackStart?()
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
        onPlaybackStart?()
        audioSession.activate()
        ensureEngineRunning()
        engine.mainMixerNode.outputVolume = normalVolume
        cancelDecode()
        switch item.source {
        case .file(let url):
            guard let scheduleID = scheduleFile(item, url: url, on: activePlayer, startNow: true) else { return }
            activeScheduleID = scheduleID
            commitCurrent(item)
            preloadNext(after: item.id)
        case .mediaLibrary(let ref):
            // Commit to the track now; audio begins when the async decode lands.
            commitCurrent(item)
            startMediaPlayback(item, ref: ref, on: activePlayer)
            preloadNext(after: item.id)
        }
    }

    /// Shared post-schedule bookkeeping for the now-current track.
    private func commitCurrent(_ item: QueueItem) {
        currentItem = item
        currentDuration = duration(of: item)
        setState(.playing(item.id))
        queue.clearAnchor(ifMatches: item.id)
    }

    /// Schedules a FILE item on `player`. Returns the unique schedule token, or nil
    /// if the file couldn't be opened.
    private func scheduleFile(_ item: QueueItem, url: URL, on player: AVAudioPlayerNode, startNow: Bool) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else {
            ptLog("schedule FAILED to open \(item.filename)")
            return nil
        }
        let scheduleID = beginSchedule(item, on: player, format: file.processingFormat)
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.handleScheduleEnded(scheduleID) }
        }
        if startNow { player.play() }
        ptLog("schedule file \(item.filename)#\(item.id.uuidString.prefix(4)) sid=\(scheduleID) startNow=\(startNow)")
        return scheduleID
    }

    /// Common scheduling prologue: issue a new token, (re)connect at `format`, stop
    /// the node, and apply per-track ReplayGain. The gain lives on the player node's
    /// own volume, so it rides with the node through the active/standby swap and
    /// composes multiplicatively with the mixer's fade lever. Returns the token.
    private func beginSchedule(_ item: QueueItem, on player: AVAudioPlayerNode, format: AVAudioFormat) -> Int {
        scheduleSeq += 1
        let scheduleID = scheduleSeq
        connectIfNeeded(player, format: format)
        player.stop()
        player.volume = trackGainScale(for: item)
        return scheduleID
    }

    /// Stream a media item off-main: the decoder hands over one short PCM chunk at
    /// a time and each is scheduled (on main) behind the last, so playback starts
    /// after the first chunk instead of after the whole track and only a few
    /// seconds of audio is ever resident. `decodeToken` guards against a newer
    /// decode superseding this one; the current-item check guards against a queue
    /// edit mid-stream. There is no gapless preload for media — the first chunk is
    /// started the moment it lands (a small gap is accepted).
    private func startMediaPlayback(_ item: QueueItem, ref: MediaRef, on player: AVAudioPlayerNode) {
        guard let assetURL = ref.assetURL else {
            ptLog("media \(item.filename) has no asset URL → skip")
            handleMediaDecodeFailure(for: item.id)
            return
        }
        decodeToken += 1
        let token = decodeToken
        let decoder = MediaTrackDecoder()
        activeDecoder = decoder
        mediaStream = MediaStream(token: token, itemID: item.id)
        decodeQueue.async { [weak self] in
            do {
                try decoder.decode(assetURL: assetURL) { buffer, isLast in
                    DispatchQueue.main.async {
                        guard let self else { decoder.cancel(); return }
                        self.scheduleMediaChunk(buffer, isLast: isLast, for: item,
                                                on: player, decoder: decoder, token: token)
                    }
                }
                DispatchQueue.main.async { self?.noteMediaDecodeFinished(token: token) }
            } catch {
                DispatchQueue.main.async { self?.noteMediaDecodeFailed(token: token, error: error) }
            }
        }
    }

    /// Schedule one decoded chunk on `player`. The first chunk owns the schedule
    /// prologue (format connect, node stop, ReplayGain) and issues the token the
    /// whole stream is identified by; later chunks simply queue behind it, which is
    /// gapless. A chunk that arrives for a superseded stream is dropped and the
    /// decoder cancelled, which also unparks its decode thread.
    private func scheduleMediaChunk(_ buffer: AVAudioPCMBuffer, isLast: Bool, for item: QueueItem,
                                    on player: AVAudioPlayerNode, decoder: MediaTrackDecoder, token: Int) {
        guard token == decodeToken, var stream = mediaStream, stream.token == token,
              state.currentItemID == item.id else {
            decoder.cancel()
            return
        }
        if stream.scheduled == 0 {
            stream.scheduleID = beginSchedule(item, on: player, format: buffer.format)
            activeScheduleID = stream.scheduleID
            ptLog("stream media \(item.filename)#\(item.id.uuidString.prefix(4)) sid=\(stream.scheduleID)")
        }
        // If an interruption paused us mid-stream, schedule without playing so
        // resume() starts it; otherwise the first chunk starts the deck.
        let startNow = stream.scheduled == 0 && state.isPlaying
        stream.scheduled += 1
        mediaStream = stream
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            decoder.releaseChunk()   // free a slot so the decoder can produce the next
            DispatchQueue.main.async { self?.handleMediaChunkPlayed(token: token) }
        }
        if startNow { player.play() }
        if isLast { noteMediaDecodeFinished(token: token) }
    }

    private func handleMediaChunkPlayed(token: Int) {
        guard var stream = mediaStream, stream.token == token else { return }
        stream.played += 1
        mediaStream = stream
        finishMediaStreamIfComplete()
    }

    /// The decoder has no more chunks to give. The track ends once the ones
    /// already scheduled have played out.
    private func noteMediaDecodeFinished(token: Int) {
        guard token == decodeToken else { return }
        activeDecoder = nil
        guard var stream = mediaStream, stream.token == token, !stream.decodeFinished else { return }
        stream.decodeFinished = true
        mediaStream = stream
        finishMediaStreamIfComplete()
    }

    /// A decode that ended badly. Nothing scheduled yet ⇒ the track never started,
    /// so skip it like a file that wouldn't open. Otherwise let the chunks we do
    /// have play out and treat that as the end of the track.
    private func noteMediaDecodeFailed(token: Int, error: Error) {
        guard token == decodeToken, let stream = mediaStream, stream.token == token else { return }
        activeDecoder = nil
        guard stream.scheduled > 0 else {
            ptLog("media decode FAILED: \(error)")
            mediaStream = nil
            handleMediaDecodeFailure(for: stream.itemID)
            return
        }
        ptLog("media decode ended early: \(error)")
        noteMediaDecodeFinished(token: token)
    }

    /// End of a media track: every handed-over chunk has played back. Routed
    /// through the same completion path a file's single schedule uses.
    private func finishMediaStreamIfComplete() {
        guard let stream = mediaStream, stream.isComplete else { return }
        mediaStream = nil
        handleScheduleEnded(stream.scheduleID)
    }

    /// A media item that couldn't be decoded behaves like a file that wouldn't
    /// open: move past it (or stop if it was the last track).
    private func handleMediaDecodeFailure(for itemID: UUID) {
        guard state.currentItemID == itemID else { return }
        advance()
    }

    /// Cancel any in-flight media decode and invalidate its pending chunks.
    private func cancelDecode() {
        activeDecoder?.cancel()
        activeDecoder = nil
        mediaStream = nil
        decodeToken += 1
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
        // Only file items preload gaplessly on standby. Media items are decoded and
        // scheduled at advance() time (no gapless), so clear any prior preload.
        guard case .file(let url) = next.source,
              let scheduleID = scheduleFile(next, url: url, on: standbyPlayer, startNow: false) else {
            preloadedItemID = nil
            preloadedScheduleID = 0
            return
        }
        preloadedItemID = next.id
        preloadedScheduleID = scheduleID
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
        cancelDecode()
        activePlayer.stop()

        guard let next = queue.item(after: currentID) else {
            ptLog("advance current=\(currentID.uuidString.prefix(4)) next=nil → stop | queue: \(queue.debugOrder)")
            stop()                       // queue exhausted
            return
        }
        ptLog("advance current=\(currentID.uuidString.prefix(4)) next=\(next.filename)#\(next.id.uuidString.prefix(4)) preloaded=\(preloadedItemID?.uuidString.prefix(4) ?? "nil") | queue: \(queue.debugOrder)")

        switch next.source {
        case .file(let url):
            if preloadedItemID != next.id {
                guard let scheduleID = scheduleFile(next, url: url, on: standbyPlayer, startNow: false) else {
                    stop(); return
                }
                preloadedItemID = next.id
                preloadedScheduleID = scheduleID
            }
            swap(&activePlayer, &standbyPlayer)   // standby (holding `next`) becomes active
            activeScheduleID = preloadedScheduleID
            engine.mainMixerNode.outputVolume = normalVolume
            activePlayer.play()
            commitCurrent(next)
            preloadNext(after: next.id)
        case .mediaLibrary(let ref):
            // No gapless for media: reuse the just-stopped active deck and decode
            // asynchronously. Any stale preload on standby is overwritten by the
            // next preloadNext.
            preloadedItemID = nil
            preloadedScheduleID = 0
            engine.mainMixerNode.outputVolume = normalVolume
            commitCurrent(next)
            startMediaPlayback(next, ref: ref, on: activePlayer)
            preloadNext(after: next.id)
        }
    }

    private func finishFadeStop() {
        ptLog("fade complete → idle")
        cancelDecode()
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

    /// Track length: from the MPMediaItem for media (no AVAudioFile probe), or the
    /// file's frame count for files.
    private func duration(of item: QueueItem) -> TimeInterval {
        switch item.source {
        case .file(let url): return duration(of: url)
        case .mediaLibrary(let ref): return ref.duration
        }
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
