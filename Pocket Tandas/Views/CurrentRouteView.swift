// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  CurrentRouteView.swift
//  Pocket Tandas
//
//  Small label showing the active output route alongside the route picker.
//

import SwiftUI

struct CurrentRouteView: View {
    let description: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wave.3.right")
            Text(description)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    CurrentRouteView(description: "MacBook Pro Speakers")
}
