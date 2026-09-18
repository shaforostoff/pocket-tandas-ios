// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioSessionController.swift
//  Pocket Tandas
//
//  Owns AVAudioSession configuration and activation, publishes the current
//  output route for display, and forwards interruption / route-change events
//  to the playback engine (wired in later milestones). iOS controls the final
//  output routing; the user picks devices via the system route picker.
//
//  Activation is REFERENCE-COUNTED (see `Holder`): the session goes live for the
//  first thing that needs it and is released once the last one lets go. Leaving a
//  `.playback` session active with nothing to play keeps the app in the system's
//  Now Playing slot, so the lock screen shows our transport controls — empty, if
//  nothing published Now Playing info — for as long as the process lives.
//

import Foundation
import AVFoundation
import Observation

/// Plain `@Observable` (not actor-isolated) so it can be created as the App's
/// `@State` default and read directly from SwiftUI view bodies. Mutations happen
/// on the main thread: notifications below are delivered on `.main`.
@Observable
final class AudioSessionController {
    /// The things that can need the audio session live. The session is activated
    /// for the first holder and deactivated once the last one releases.
    enum Holder: String, Hashable {
        /// Queue playback (PlaybackEngine). Held while playing OR paused, so a
        /// paused track keeps its lock-screen controls.
        case queue
        /// Explore-mode auditioning (PreListenPlayer).
        case prelisten
        /// The sideload-only silent keep-alive (SilentKeepAlive).
        case keepAlive
    }

    /// Human-readable description of the current output route(s).
    private(set) var currentRouteDescription: String = "System default"

    // Hooks the PlaybackEngine attaches to. Nil until later milestones wire them.
    @ObservationIgnored var onInterruptionBegan: (() -> Void)?
    @ObservationIgnored var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    @ObservationIgnored var onRouteChanged: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Who currently needs the session. Not observed: this is lifecycle
    /// bookkeeping, and mutating it must not invalidate any view.
    @ObservationIgnored private var holders: Set<Holder> = []
    @ObservationIgnored private var releaseScheduled = false

    init() {
        configureCategory()
        registerObservers()
        refreshRoute()
    }

    /// `.playback` keeps audio alive when the screen locks / app is backgrounded;
    /// the options allow Bluetooth A2DP and AirPlay outputs (USB routes through the
    /// standard output automatically — there is no separate USB option).
    func configureCategory() {
        do {
            try session.setCategory(.playback, mode: .default,
                                    options: [.allowBluetoothA2DP, .allowAirPlay])
        } catch {
            ptLog("[AudioSession] setCategory failed: \(error)")
        }
    }

    /// Take the session live on `holder`'s behalf. Idempotent per holder.
    func activate(for holder: Holder) {
        holders.insert(holder)
        do {
            try session.setActive(true)
            refreshRoute()
        } catch {
            ptLog("[AudioSession] activate failed: \(error)")
        }
    }

    /// Let go of `holder`; the session is deactivated once nobody holds it.
    func release(_ holder: Holder) {
        guard holders.remove(holder) != nil else { return }
        scheduleReleaseIfIdle()
    }

    /// Deactivation waits for the next runloop turn so a hand-off doesn't bounce
    /// the session off and back on: queue playback starting tears prelistening
    /// down first (see PlaybackEngine.startPlaying), and both happen in the same
    /// turn. Re-checking `holders` there means only a genuinely idle app releases.
    private func scheduleReleaseIfIdle() {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.releaseScheduled = false
            guard self.holders.isEmpty else { return }
            self.deactivate()
        }
    }

    private func deactivate(notifyOthers: Bool = true) {
        do {
            try session.setActive(false, options: notifyOthers ? [.notifyOthersOnDeactivation] : [])
            ptLog("[AudioSession] released — nothing holds it")
        } catch {
            ptLog("[AudioSession] deactivate failed: \(error)")
        }
    }

    private func refreshRoute() {
        let outputs = session.currentRoute.outputs
        currentRouteDescription = outputs.isEmpty
            ? "No output"
            : outputs.map(\.portName).joined(separator: ", ")
    }

    private func registerObservers() {
        let nc = NotificationCenter.default
        let interruption = nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                          object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
        let route = nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                   object: session, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        }
        observers = [interruption, route]
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            var shouldResume = false
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume)
            }
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        refreshRoute()
        onRouteChanged?()
    }
}
