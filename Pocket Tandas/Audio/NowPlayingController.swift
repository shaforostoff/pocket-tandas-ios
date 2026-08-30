// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  NowPlayingController.swift
//  Pocket Tandas
//
//  Bridges the engine to the system: populates the lock-screen / Control Center
//  Now Playing info and handles remote commands. Having these wired also helps
//  iOS keep the app alive while backgrounded.
//
//  TWO sources can be sounding, and whichever is takes the lock screen: the play
//  queue (PlaybackEngine, full transport) and an Explore-mode audition
//  (PreListenPlayer, Stop only — a prelisten has no pause or skip in the app
//  either). When neither is, the info is cleared AND every command disabled, so
//  the system stops offering a transport for an app with nothing to play. That
//  teardown matters most in Remote Control mode, where the local queue never
//  plays: without it an audition (or the silent keep-alive) left the app in the
//  Now Playing slot for the rest of the process's life, showing dead play/stop
//  buttons with no track details. The other half of that fix is releasing the
//  audio session — see AudioSessionController.Holder.
//

import Foundation
import MediaPlayer

final class NowPlayingController {
    /// What the lock screen is currently showing, if anything.
    private enum Source {
        case queue(QueueItem)
        case prelisten(PreListenTrack)
    }

    private let engine: PlaybackEngine
    private let preListen: PreListenPlayer
    private let metadata: MetadataService
    private let library: LibraryStore
    private var clearScheduled = false

    init(engine: PlaybackEngine, preListen: PreListenPlayer, metadata: MetadataService, library: LibraryStore) {
        self.engine = engine
        self.preListen = preListen
        self.metadata = metadata
        self.library = library
        configureCommands()
        engine.onStateChange = { [weak self] in self?.updateNowPlayingInfo() }
        preListen.onStateChange = { [weak self] in self?.updateNowPlayingInfo() }
        updateNowPlayingInfo()
    }

    /// The queue wins if it has a track loaded (playing or paused): starting queue
    /// playback stops any audition, so both are only ever briefly true at once.
    private var source: Source? {
        if let item = engine.currentItem { return .queue(item) }
        if let track = preListen.current { return .prelisten(track) }
        return nil
    }

    // MARK: - Remote commands

    /// Targets are added once and stay; what changes with the source is which
    /// commands are ENABLED (`setCommandsEnabled`), which is what the system reads
    /// when deciding which buttons to draw.
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.engine.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.engine.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.engine.state.isPlaying { self.engine.pause() } else { self.engine.resume() }
            return .success
        }
        // Stop applies to whichever source is sounding — the only command an
        // audition answers.
        center.stopCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            switch self.source {
            case .queue: self.engine.stop()
            case .prelisten: self.preListen.stop()
            case nil: return .noSuchContent
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.engine.skipToNext()
            return .success
        }
        center.previousTrackCommand.isEnabled = false
        setCommandsEnabled(transport: false, stop: false)
    }

    /// `transport` covers the commands only the queue can answer (play / pause /
    /// toggle / next); `stop` is separate because an audition answers it too.
    private func setCommandsEnabled(transport: Bool, stop: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = transport
        center.pauseCommand.isEnabled = transport
        center.togglePlayPauseCommand.isEnabled = transport
        center.nextTrackCommand.isEnabled = transport
        center.stopCommand.isEnabled = stop
    }

    // MARK: - Now Playing info

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()

        switch source {
        case .queue(let item):
            setCommandsEnabled(transport: true, stop: true)
            var info = baseInfo(title: item.filename, snapshot: metadata.snapshot(forKey: item.trackKey))
            info[MPMediaItemPropertyPlaybackDuration] = engine.currentDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentElapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state.isPlaying ? 1.0 : 0.0
            center.nowPlayingInfo = info
            center.playbackState = engine.state.isPlaying ? .playing : .paused

        case .prelisten(let track):
            setCommandsEnabled(transport: false, stop: true)
            var info = baseInfo(title: prelistenTitle(track), snapshot: prelistenSnapshot(track))
            info[MPMediaItemPropertyPlaybackDuration] = preListen.currentDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = preListen.currentElapsed
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            center.nowPlayingInfo = info
            center.playbackState = .playing

        case nil:
            clearIfStillIdle()
        }
    }

    /// Give up the lock screen once nothing is sounding.
    ///
    /// Deferred a runloop turn and re-checked, because "nothing is sounding" is
    /// briefly true mid-hand-off: starting queue playback stops any audition first
    /// (PlaybackEngine.startPlaying), so clearing eagerly would blank the lock
    /// screen for an instant on every tap. Mirrors the audio session's own
    /// deferred release.
    ///
    /// Both halves matter: clearing the info alone leaves the app in the Now
    /// Playing slot with blank details, and disabling the commands alone leaves
    /// that empty entry there too.
    private func clearIfStillIdle() {
        guard !clearScheduled else { return }
        clearScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearScheduled = false
            guard self.source == nil else { return }
            self.setCommandsEnabled(transport: false, stop: false)
            let center = MPNowPlayingInfoCenter.default()
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }

    /// Title / artist / genre, falling back to the filename when nothing is cached.
    private func baseInfo(title fallbackTitle: String, snapshot: TrackMetadataSnapshot?) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = snapshot?.title ?? fallbackTitle
        if let artist = snapshot?.artist { info[MPMediaItemPropertyArtist] = artist }
        if let genre = snapshot?.genre { info[MPMediaItemPropertyGenre] = genre }
        return info
    }

    /// A file audition reads the same metadata cache the browser rows do; a library
    /// audition carries its details from the MPMediaItem the player resolved.
    private func prelistenSnapshot(_ track: PreListenTrack) -> TrackMetadataSnapshot? {
        switch track {
        case .file(let url): return metadata.snapshot(for: url, baseURL: library.baseURL)
        case .media: return preListen.mediaMetadata
        }
    }

    private func prelistenTitle(_ track: PreListenTrack) -> String {
        switch track {
        case .file(let url): return url.lastPathComponent
        case .media: return "Music library track"
        }
    }
}
