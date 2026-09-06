// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RoutePickerView.swift
//  Pocket Tandas
//
//  SwiftUI wrapper for AVRoutePickerView — Apple's system control for choosing
//  the audio output route (Bluetooth / AirPlay / USB / built-in). This is the
//  sanctioned way to let the user pick an output, since iOS has no API to force
//  a specific output device programmatically.
//

import SwiftUI
import AVKit

struct RoutePickerView: UIViewRepresentable {
    var tintColor: UIColor = .label
    var activeTintColor: UIColor = .tintColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
