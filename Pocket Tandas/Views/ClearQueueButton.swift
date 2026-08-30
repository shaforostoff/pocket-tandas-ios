// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  ClearQueueButton.swift
//  Pocket Tandas
//
//  Explore-mode control bar button: empty the play queue, behind a confirmation
//  so a stray tap can't wipe a queue the user built up.
//

import SwiftUI

struct ClearQueueButton: View {
    @Environment(PlayQueue.self) private var queue
    @State private var confirming = false

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            Label("Clear", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(queue.items.isEmpty)
        .confirmationDialog("Clear the play queue?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Clear Queue", role: .destructive) { queue.removeAll() }
            Button("Cancel", role: .cancel) { }
        }
    }
}
