// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioOutputDevice.swift (macOS)
//  Pocket Tandas
//
//  CoreAudio output-device enumeration, the thing iOS has no equivalent of and
//  the reason a Mac can do what the phone cannot: iOS gives the whole app ONE
//  system-chosen route, so the queue and the cue must share it. macOS lets each
//  engine name its own hardware device, so the queue can go to the interface
//  feeding the room while the cue goes to the headphones on the DJ's neck.
//
//  Devices are identified to the rest of the app by UID, not by AudioDeviceID:
//  the integer id is assigned per boot and changes when a device is unplugged and
//  plugged back in, while the UID is stable and is what gets persisted. Callers
//  resolve a UID to a live id at the moment they need one (`Self.id(forUID:)`),
//  and get nil when the device isn't currently attached — which is the honest
//  answer, and means "fall back to the system default".
//

import Foundation
import AVFoundation
import CoreAudio

struct AudioOutputDevice: Identifiable, Hashable {
    /// Live CoreAudio id. Valid only for as long as the device stays attached.
    let id: AudioDeviceID
    /// Stable across unplug/replug and reboots — this is what gets persisted.
    let uid: String
    let name: String
    /// Total output channels. A 4+ channel interface is what real DJ cueing wants.
    let channelCount: Int
}

enum AudioOutputDevices {
    /// Every device with at least one output channel, in CoreAudio's order.
    static func all() -> [AudioOutputDevice] {
        deviceIDs().compactMap { id in
            let channels = outputChannelCount(of: id)
            guard channels > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, channelCount: channels)
        }
    }

    /// Resolve a persisted UID to a live id, or nil when that device is gone.
    static func id(forUID uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    /// The system's current default output device.
    static func defaultOutputID() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    // MARK: - Binding, and the stale-driver hazard

    /// Point `unit` at `deviceID`, giving up after `timeout` seconds.
    ///
    /// The timeout is not defensive padding, it is load-bearing. `setDeviceID`
    /// talks to the device's driver over Mach IPC, and a STALE VIRTUAL DEVICE —
    /// a loopback or meeting-app driver still registered with CoreAudio after
    /// the process behind it is gone — never answers. Measured on a machine with
    /// a dormant "Microsoft Teams Audio" loopback: the call blocks in
    /// `HALC_ProxyObject::HasProperty` forever. Run on the main thread from
    /// `init`, that would wedge the app at launch every time, because the choice
    /// that triggers it is the persisted one.
    ///
    /// So the call is made off-thread and abandoned if it doesn't come back. The
    /// abandoned thread stays blocked for the life of the process, which is why
    /// callers should cache the verdict (see `isResponsive`) rather than retry.
    @discardableResult
    static func bind(_ deviceID: AudioDeviceID, to unit: AUAudioUnit,
                     timeout: TimeInterval = 3) -> Bool {
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try unit.setDeviceID(deviceID) } catch { box.error = error }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            ptLog("[AudioDevices] device \(deviceID) did not answer in \(timeout)s — abandoning it")
            return false
        }
        if let error = box.error {
            ptLog("[AudioDevices] could not bind device \(deviceID): \(error)")
            return false
        }
        return true
    }

    /// Probe engines whose bind never came back. Held for the life of the process
    /// deliberately: the thread still stuck inside `setDeviceID` owns a reference
    /// into this engine's audio unit, and releasing it out from under that thread
    /// is a segfault, not a leak worth reclaiming. At most one per bad device,
    /// because `isResponsive`'s callers cache the verdict.
    private static var strandedProbes: [AVAudioEngine] = []

    /// Whether a device's driver answers at all, decided by binding a throwaway
    /// engine to it. Used to keep an unresponsive device away from the cue, whose
    /// own hazard shows up later and messier — `AVAudioPlayer.currentDevice`
    /// accepts the UID happily and it is `play()` that then never returns.
    ///
    /// Costs microseconds for a healthy device. Cache the answer: an unhealthy one
    /// costs `timeout` seconds and strands both a thread and this engine.
    ///
    /// The probe engine must outlive the call. Passing `AVAudioEngine().output…`
    /// inline does not: the temporary is released while the background thread is
    /// still inside `setDeviceID`, and the process dies on SIGSEGV — which is
    /// what the first version of this did.
    static func isResponsive(_ deviceID: AudioDeviceID, timeout: TimeInterval = 2) -> Bool {
        let probe = AVAudioEngine()
        let responded = bind(deviceID, to: probe.outputNode.auAudioUnit, timeout: timeout)
        if !responded { strandedProbes.append(probe) }
        return withExtendedLifetime(probe) { responded }
    }

    // MARK: - CoreAudio plumbing

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// Summed channels across the device's output streams. Zero means it is an
    /// input-only device (a microphone), which this app has no use for.
    private static func outputChannelCount(of id: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        // A CFStringRef the caller owns — `takeRetainedValue` balances it.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}
