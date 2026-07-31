// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EQButton.swift
//  Pocket Tandas
//
//  Control-bar button, sitting to the left of Stop. Opens the parametric EQ panel;
//  tinted while the EQ is actively colouring the sound so the DJ can tell at a
//  glance it is engaged. Always tappable (EQ can be set before play).
//
//  The control it drives is either the local Equalizer (DJ / Remote Controllable)
//  or the receiver's EQ over the peer link (Remote Control) — see
//  EqualizerControlling.
//

import SwiftUI

struct EQButton: View {
    let control: any EqualizerControlling
    /// Shown in the panel and disables it while a remote EQ hasn't reported yet.
    var isReady: Bool = true

    @State private var showingPanel = false

    var body: some View {
        Button {
            showingPanel = true
        } label: {
            Label("EQ", systemImage: "slider.vertical.3")
        }
        .buttonStyle(.bordered)
        .tint(control.isActive ? Color.accentColor : nil)
        .sheet(isPresented: $showingPanel) {
            EqualizerView(control: control, isReady: isReady)
        }
    }
}
