// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SortOption.swift
//  Pocket Tandas
//

import Foundation

enum SortOption: String, CaseIterable, Identifiable {
    case filename
    case dateYear
    case bpm
    case artist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filename: return "Filename"
        case .dateYear: return "Date / Year"
        case .bpm: return "BPM"
        case .artist: return "Artist"
        }
    }

    var systemImage: String {
        switch self {
        case .filename: return "textformat"
        case .dateYear: return "calendar"
        case .bpm: return "metronome"
        case .artist: return "person"
        }
    }
}

enum SortDirection {
    case ascending
    case descending

    mutating func toggle() {
        self = (self == .ascending) ? .descending : .ascending
    }
}
