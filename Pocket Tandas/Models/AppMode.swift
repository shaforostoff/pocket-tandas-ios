// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AppMode.swift
//  Pocket Tandas
//
//  The shared main screen carries this flag. Both launcher buttons currently
//  lead to identical behaviour; the seam is here for future divergence.
//

import Foundation

enum AppMode: String, Identifiable, Hashable, CaseIterable {
    case explore
    case dj

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .dj: return "DJ Mode"
        }
    }
}
