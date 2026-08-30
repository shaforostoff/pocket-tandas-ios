// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StayAwake.swift
//  Pocket Tandas
//
//  Two opt-in ways to stop iOS suspending the app while it sits idle — which is
//  what makes a Remote Controllable phone unreachable after the screen locks
//  (MultipeerConnectivity has no background mode of its own; the link only
//  survives suspension when something keeps the process running):
//
//   - "Screen stays awake" — the idle timer is disabled, so the phone doesn't
//     auto-lock. Handled by MainScreenView.
//   - "Silent keep-alive audio" — SilentKeepAlive below renders silence on its own
//     engine, so the app's `audio` background mode keeps it alive with the screen
//     off. Note the App Store frowns on background audio that isn't user-facing
//     (guideline 2.5.4), which is why this is off by default and time-limited.
//
//  Both are launcher toggles, both default OFF, and both release after 30 minutes
//  so a switch left on can't drain the battery all night. The window restarts each
//  time the app comes back to the foreground.
//

import Foundation
import AVFoundation

enum StayAwakeSettings {
    static let screenAwakeKey = "remote.screenStaysAwake"
    static let silentKeepAliveKey = "remote.silentKeepAlive"

    /// How long either option holds before releasing on its own.
    static let window: TimeInterval = 30 * 60

    static var screenStaysAwake: Bool { UserDefaults.standard.bool(forKey: screenAwakeKey) }
    static var silentKeepAlive: Bool { UserDefaults.standard.bool(forKey: silentKeepAliveKey) }
}

/// Renders a looping buffer of digital silence on a dedicated AVAudioEngine, which
/// is enough for iOS to treat the app as playing and leave it running with the
/// screen locked. Separate from the PlaybackEngine so it can never disturb the
/// queue's graph, its fade lever or its EQ; it only runs while that engine is idle
/// (real playback keeps the app alive by itself).
///
/// The samples are true zeros and the mixer is left at unity — attenuating an
/// already-silent signal would only risk the system reading the app as not
/// actually playing.
final class SilentKeepAlive {
    private(set) var isRunning = false

    private let audioSession: AudioSessionController
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var observers: [NSObjectProtocol] = []

    init(audioSession: AudioSessionController) {
        self.audioSession = audioSession
        engine.attach(player)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        player.stop()
        engine.stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        ptLog("[KeepAlive] start")
        observeAudioEvents()
        render()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        ptLog("[KeepAlive] stop")
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player.stop()
        engine.stop()
        // The session is left active on purpose: deactivating it here could
        // interrupt playback that started in the meantime.
    }

    private func render() {
        guard isRunning else { return }
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 44_100
        let channels = max(1, min(2, hardware.channelCount))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else { return }
        if buffer?.format != format { buffer = Self.silentBuffer(format: format) }
        guard let buffer else { return }

        audioSession.activate()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            ptLog("[KeepAlive] engine start failed: \(error)")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }

    /// One second of silence, looped forever.
    private static func silentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channels = buffer.floatChannelData else { return nil }
        for channel in 0..<Int(format.channelCount) {
            memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
        }
        return buffer
    }

    /// A phone call or a route change stops our engine like any other; restart so
    /// the app doesn't quietly become suspendable again.
    private func observeAudioEvents() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                guard let self, self.isRunning,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self.restart()
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange,
                               object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.restart()
            },
        ]
    }

    private func restart() {
        player.stop()
        engine.stop()
        render()
    }
}
