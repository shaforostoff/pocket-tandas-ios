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

import Foundation
import MediaPlayer

final class NowPlayingController {
    private let engine: PlaybackEngine
    private let metadata: MetadataService

    init(engine: PlaybackEngine, metadata: MetadataService) {
        self.engine = engine
        self.metadata = metadata
        configureCommands()
        engine.onStateChange = { [weak self] in self?.updateNowPlayingInfo() }
    }

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
        center.stopCommand.addTarget { [weak self] _ in
            self?.engine.stop()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.engine.skipToNext()
            return .success
        }
        center.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let item = engine.currentItem else {
            center.nowPlayingInfo = nil
            return
        }

        let snapshot = metadata.snapshot(forKey: item.trackKey)
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = snapshot?.title ?? item.filename
        if let artist = snapshot?.artist { info[MPMediaItemPropertyArtist] = artist }
        if let genre = snapshot?.genre { info[MPMediaItemPropertyGenre] = genre }
        info[MPMediaItemPropertyPlaybackDuration] = engine.currentDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentElapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.state.isPlaying ? 1.0 : 0.0

        center.nowPlayingInfo = info
    }
}
