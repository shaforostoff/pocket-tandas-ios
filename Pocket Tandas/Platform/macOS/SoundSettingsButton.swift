// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SoundSettingsButton.swift (macOS)
//  Pocket Tandas
//
//  Stands in for Platform/iOS/RoutePickerView.swift, which wraps AVRoutePickerView
//  — a UIKit view with no macOS counterpart. macOS picks the output device system-
//  wide rather than per app, so the honest equivalent is a shortcut to the Sound
//  pane; the name of whatever it selects is shown next to this by CurrentRouteView.
//
//  This becomes a real per-app device picker once playback binds its engine to a
//  chosen device (AUAudioUnit.setDeviceID, macOS-only) rather than following the
//  system default.
//

import SwiftUI
import AppKit

struct SoundSettingsButton: View {
    var body: some View {
        Button {
            let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "hifispeaker.and.appletv")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .help("Open Sound settings to choose the output device")
        .accessibilityLabel("Output device settings")
    }
}
