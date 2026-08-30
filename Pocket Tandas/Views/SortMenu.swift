// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SortMenu.swift
//  Pocket Tandas
//
//  The browser's Sort control: Filename, Date/Year, BPM, Artist. Re-selecting
//  the active option toggles ascending/descending.
//

import SwiftUI

struct SortMenu: View {
    @Binding var sort: SortOption
    @Binding var direction: SortDirection
    var options: [SortOption]

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    if sort == option {
                        direction.toggle()
                    } else {
                        sort = option
                        direction = .ascending
                    }
                } label: {
                    if sort == option {
                        Label(option.label,
                              systemImage: direction == .ascending ? "chevron.up" : "chevron.down")
                    } else {
                        Label(option.label, systemImage: option.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .imageScale(.large)
        }
    }
}
