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
    case listed       // source order — a playlist's own order; not shown for folders
    case filename
    case dateYear
    case genre
    case bpm
    case artist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listed: return "Playlist Order"
        case .filename: return "Filename"
        case .dateYear: return "Date / Year"
        case .genre: return "Genre"
        case .bpm: return "BPM"
        case .artist: return "Artist"
        }
    }

    var systemImage: String {
        switch self {
        case .listed: return "list.number"
        case .filename: return "textformat"
        case .dateYear: return "calendar"
        case .genre: return "guitars"
        case .bpm: return "metronome"
        case .artist: return "person"
        }
    }

    /// Sorts that need scanned metadata. The browser holds these off until a
    /// folder/playlist scan finishes; filename and playlist order do not.
    var usesMetadata: Bool {
        switch self {
        case .listed, .filename: return false
        case .dateYear, .genre, .bpm, .artist: return true
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
