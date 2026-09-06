// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioSessionController.swift (macOS)
//  Pocket Tandas
//
//  The macOS counterpart of Platform/iOS/AudioSessionController.swift. Same
//  surface, different substance: macOS has no AVAudioSession, so there is no
//  category to configure and nothing to activate — an AVAudioEngine talks to a
//  hardware device directly, and keeps talking to it whether or not the app is
//  frontmost. `activate`/`release` therefore only keep the holder bookkeeping the
//  callers expect; nothing is claimed or surrendered.
//
//  What IS real here is the route description: CoreAudio is asked for the current
//  default output device by name, and a property listener refires `onRouteChanged`
//  when the user switches devices in Sound settings — the same signal the iOS side
//  gets from AVAudioSession.routeChangeNotification.
//
//  Interruptions have no macOS equivalent (nothing takes the output away
//  mid-render), so `onInterruptionBegan` / `onInterruptionEnded` are never called.
//

import Foundation
import CoreAudio
import Observation

/// Plain `@Observable` (not actor-isolated) to match the iOS side — see the
/// observable-not-mainactor note. The CoreAudio listener is dispatched to main.
@Observable
final class AudioSessionController {
    /// Mirrors the iOS holder set so shared callers compile unchanged. Kept as
    /// bookkeeping only: there is no session whose lifetime it could drive.
    enum Holder: String, Hashable {
        case queue
        case prelisten
        case keepAlive
    }

    /// Name of the current default output device, or a fallback if CoreAudio
    /// won't say.
    private(set) var currentRouteDescription: String = "System default"

    /// Never fired on macOS — kept so the shared wiring in PlaybackEngine and
    /// PreListenPlayer needs no platform guard of its own.
    @ObservationIgnored var onInterruptionBegan: (() -> Void)?
    @ObservationIgnored var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// Fired when the default output device changes.
    @ObservationIgnored var onRouteChanged: (() -> Void)?

    @ObservationIgnored private var holders: Set<Holder> = []
    @ObservationIgnored private var listenerBlock: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init() {
        refreshRoute()
        startListening()
    }

    deinit {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &Self.defaultOutputAddress,
                                               DispatchQueue.main, block)
    }

    /// No categories on macOS. Present so shared callers need no guard.
    func configureCategory() {}

    /// No session to take live; the engine owns its device. Holder tracking is
    /// kept because the iOS side's reference counting is part of this contract.
    func activate(for holder: Holder) {
        holders.insert(holder)
    }

    func release(_ holder: Holder) {
        holders.remove(holder)
    }

    // MARK: - Route

    private func startListening() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshRoute()
            self?.onRouteChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &Self.defaultOutputAddress,
                                                         DispatchQueue.main, block)
        guard status == noErr else {
            ptLog("[AudioSession] could not observe the default output device (\(status))")
            return
        }
        listenerBlock = block
    }

    private func refreshRoute() {
        currentRouteDescription = Self.defaultOutputDeviceName() ?? "No output"
    }

    /// The current default output device's name, via CoreAudio.
    private static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &defaultOutputAddress, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The property is a CFStringRef the caller owns, so it comes back
        // unmanaged and must be released — `takeRetainedValue` does that.
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil,
                                                    &nameSize, &name)
        guard nameStatus == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }
}
