// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  OutputDevicePickers.swift (macOS)
//  Pocket Tandas
//
//  The launcher's output section on a Mac: one device for the queue (what the
//  room hears) and another for the cue (what the DJ hears). This is the control
//  the iOS build cannot offer — see Platform/iOS/RoutePickerView.swift, which can
//  only hand the choice to the system, because iOS gives the app a single route.
//
//  Both pickers offer "System Default" as well as every attached output device.
//  A device that is unplugged while chosen stays selected — its name is still in
//  the menu as the stored UID — but playback falls back to the default until it
//  comes back, which is what `mainDeviceID` / `cueDeviceUIDIfAttached` return.
//

import SwiftUI

struct OutputDevicePickers: View {
    @Environment(AudioSessionController.self) private var audioSession

    var body: some View {
        @Bindable var session = audioSession
        VStack(alignment: .leading, spacing: 10) {
            DevicePicker(title: "Queue", systemImage: "hifispeaker",
                         help: "Where the room hears the play queue",
                         devices: audioSession.outputDevices,
                         unresponsive: audioSession.isKnownUnresponsive,
                         selection: $session.mainDeviceUID)
            DevicePicker(title: "Cue", systemImage: "headphones",
                         help: "Where you audition tracks before playing them",
                         devices: audioSession.outputDevices,
                         unresponsive: audioSession.isKnownUnresponsive,
                         selection: $session.cueDeviceUID)
            Text(statusCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Says plainly whether cueing is actually separated, since picking the same
    /// device twice silently defeats the point.
    private var statusCaption: String {
        if audioSession.outputDevices.count < 2 {
            return "Only one output device is attached — connect a second one "
                 + "(an interface, or a USB headphone adapter) to cue independently."
        }
        return audioSession.isCueSplit
            ? "Cueing is on its own device: auditioning will not be heard in the room."
            : "The cue shares the queue's device — auditioning will be heard in the room."
    }
}

/// One labelled device menu. Nil selection means "System Default".
private struct DevicePicker: View {
    let title: String
    let systemImage: String
    let help: String
    let devices: [AudioOutputDevice]
    /// Asked per row; never probes, so drawing the menu can't block.
    let unresponsive: (String) -> Bool
    @Binding var selection: String?

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(width: 80, alignment: .leading)
            Picker(title, selection: $selection) {
                Text("System Default").tag(String?.none)
                Divider()
                ForEach(devices) { device in
                    Text(label(for: device)).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .help(help)
        }
    }

    /// Channel count is worth showing: a 4-channel interface is what makes a real
    /// booth split possible, and a 1-channel loopback is worth spotting too.
    private func label(for device: AudioOutputDevice) -> String {
        var label = device.name
        if device.channelCount != 2 { label += " (\(device.channelCount) ch)" }
        // A driver that has stopped answering stays in CoreAudio's list and looks
        // perfectly ordinary, so say so rather than let it be picked blind.
        if unresponsive(device.uid) { label += " — not responding" }
        return label
    }
}
