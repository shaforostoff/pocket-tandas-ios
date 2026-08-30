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

import Foundation
import AVFoundation
import Observation

/// Plain `@Observable` (not actor-isolated) so it can be created as the App's
/// `@State` default and read directly from SwiftUI view bodies. Mutations happen
/// on the main thread: notifications below are delivered on `.main`.
@Observable
final class AudioSessionController {
    /// Human-readable description of the current output route(s).
    private(set) var currentRouteDescription: String = "System default"

    // Hooks the PlaybackEngine attaches to. Nil until later milestones wire them.
    @ObservationIgnored var onInterruptionBegan: (() -> Void)?
    @ObservationIgnored var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    @ObservationIgnored var onRouteChanged: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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
            print("[AudioSession] setCategory failed: \(error)")
        }
    }

    func activate() {
        do {
            try session.setActive(true)
            refreshRoute()
        } catch {
            print("[AudioSession] activate failed: \(error)")
        }
    }

    func deactivate(notifyOthers: Bool = true) {
        do {
            try session.setActive(false, options: notifyOthers ? [.notifyOthersOnDeactivation] : [])
        } catch {
            print("[AudioSession] deactivate failed: \(error)")
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
