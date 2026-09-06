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

    // MARK: - Per-device routing

    static let mainDeviceKey = "macos.output.mainDeviceUID"
    static let cueDeviceKey = "macos.output.cueDeviceUID"

    /// Every attached output device, refreshed when the hardware list changes.
    private(set) var outputDevices: [AudioOutputDevice] = []

    /// Chosen device UIDs, or nil for "follow the system default". Persisted by
    /// UID because AudioDeviceIDs are only valid for one attachment (see
    /// AudioOutputDevice.swift).
    var mainDeviceUID: String? {
        didSet {
            guard mainDeviceUID != oldValue else { return }
            persist(mainDeviceUID, forKey: Self.mainDeviceKey)
            refreshRoute()
            onMainDeviceChanged?()
        }
    }

    /// The cue's device. Distinct from `mainDeviceUID` is the whole point — that
    /// is the split iOS cannot do.
    var cueDeviceUID: String? {
        didSet {
            guard cueDeviceUID != oldValue else { return }
            persist(cueDeviceUID, forKey: Self.cueDeviceKey)
        }
    }

    /// Fired when the queue's device selection changes, so PlaybackEngine can
    /// rebind its engine. The cue needs no signal: it sets the device on each
    /// freshly created player.
    @ObservationIgnored var onMainDeviceChanged: (() -> Void)?

    /// Live id for the queue's device, or nil to leave the engine on the system
    /// default (also the answer when the chosen device has been unplugged).
    var mainDeviceID: AudioDeviceID? {
        guard let uid = mainDeviceUID else { return nil }
        return AudioOutputDevices.id(forUID: uid)
    }

    /// UID for the cue's device, or nil for the system default. Handed straight
    /// to `AVAudioPlayer.currentDevice`, which takes a UID rather than an id.
    ///
    /// Nil when the device has been unplugged, and also when its driver doesn't
    /// answer: `currentDevice` accepts any UID without complaint and it is the
    /// following `play()` that hangs forever, so an unresponsive device has to be
    /// kept away from the cue rather than merely reported (see
    /// `AudioOutputDevices.isResponsive`).
    var cueDeviceUIDIfAttached: String? {
        guard let uid = cueDeviceUID,
              let id = AudioOutputDevices.id(forUID: uid),
              isResponsive(id, uid: uid) else { return nil }
        return uid
    }

    /// Cached per UID: probing costs the full timeout for a dead device and
    /// strands the thread that asked, so each is asked about at most once.
    @ObservationIgnored private var responsiveByUID: [String: Bool] = [:]

    func isResponsive(_ id: AudioDeviceID, uid: String) -> Bool {
        if let known = responsiveByUID[uid] { return known }
        let ok = AudioOutputDevices.isResponsive(id)
        responsiveByUID[uid] = ok
        if !ok { ptLog("[AudioSession] \(uid) is not answering — falling back to the default") }
        return ok
    }

    /// Whether a device is known to be unresponsive, for the picker to say so.
    /// Never probes: the menu must not block while it is being drawn.
    func isKnownUnresponsive(_ uid: String) -> Bool {
        responsiveByUID[uid] == false
    }

    /// Whether the queue and the cue are on genuinely different hardware.
    var isCueSplit: Bool {
        guard let cue = cueDeviceUIDIfAttached else { return false }
        return cue != (mainDeviceUID ?? systemDefaultUID)
    }

    private var systemDefaultUID: String? {
        guard let id = AudioOutputDevices.defaultOutputID() else { return nil }
        return outputDevices.first { $0.id == id }?.uid
    }

    @ObservationIgnored private var holders: Set<Holder> = []
    @ObservationIgnored private var listenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init() {
        outputDevices = AudioOutputDevices.all()
        mainDeviceUID = UserDefaults.standard.string(forKey: Self.mainDeviceKey)
        cueDeviceUID = UserDefaults.standard.string(forKey: Self.cueDeviceKey)
        refreshRoute()
        startListening()
    }

    private func persist(_ uid: String?, forKey key: String) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    deinit {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.defaultOutputAddress,
                                                   DispatchQueue.main, block)
        }
        if let block = deviceListListenerBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.deviceListAddress,
                                                   DispatchQueue.main, block)
        }
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
        if status == noErr {
            listenerBlock = block
        } else {
            ptLog("[AudioSession] could not observe the default output device (\(status))")
        }

        // Plugging an interface in or pulling it out changes the picker's list and
        // can invalidate a chosen device, so the queue re-resolves its own.
        let deviceListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.outputDevices = AudioOutputDevices.all()
            self.onMainDeviceChanged?()
        }
        let listStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                             &Self.deviceListAddress,
                                                             DispatchQueue.main, deviceListBlock)
        if listStatus == noErr {
            deviceListListenerBlock = deviceListBlock
        } else {
            ptLog("[AudioSession] could not observe the device list (\(listStatus))")
        }
    }

    /// What the launcher prints. The chosen queue device when there is one (and
    /// it is still attached), otherwise whatever the system is currently using.
    private func refreshRoute() {
        if let uid = mainDeviceUID,
           let chosen = outputDevices.first(where: { $0.uid == uid }) {
            currentRouteDescription = chosen.name
            return
        }
        let systemName = AudioOutputDevices.defaultOutputID().flatMap(AudioOutputDevices.name(of:))
        currentRouteDescription = systemName ?? "No output"
    }
}
