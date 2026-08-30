// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EQButton.swift
//  Pocket Tandas
//
//  DJ-mode control-bar button, sitting to the left of Stop. Opens the parametric
//  EQ panel; tinted while the EQ is actively colouring the sound so the DJ can
//  tell at a glance it is engaged. Always tappable (EQ can be set before play).
//

import SwiftUI

struct EQButton: View {
    @Environment(Equalizer.self) private var equalizer
    @State private var showingPanel = false

    var body: some View {
        Button {
            showingPanel = true
        } label: {
            Label("EQ", systemImage: "slider.vertical.3")
        }
        .buttonStyle(.bordered)
        .tint(equalizer.isActive ? Color.accentColor : nil)
        .sheet(isPresented: $showingPanel) {
            EqualizerView()
        }
    }
}
