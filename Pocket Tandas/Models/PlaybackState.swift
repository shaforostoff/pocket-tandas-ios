// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaybackState.swift
//  Pocket Tandas
//
//  Single source of truth for what the engine is doing. The associated value is
//  the QueueItem.ID currently loaded, so the UI can mark the playing row and the
//  Stop/Resume control can react to a fade in progress.
//

import Foundation

enum PlaybackState: Equatable {
    case idle
    case playing(UUID)
    case fadingOut(UUID)
    case paused(UUID)

    var currentItemID: UUID? {
        switch self {
        case .idle: return nil
        case .playing(let id), .fadingOut(let id), .paused(let id): return id
        }
    }

    var isFadingOut: Bool {
        if case .fadingOut = self { return true }
        return false
    }

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// Short label for diagnostic logging, e.g. "playing(a1b2)".
    var debugLabel: String {
        func short(_ id: UUID) -> String { String(id.uuidString.prefix(4)) }
        switch self {
        case .idle: return "idle"
        case .playing(let id): return "playing(\(short(id)))"
        case .fadingOut(let id): return "fadingOut(\(short(id)))"
        case .paused(let id): return "paused(\(short(id)))"
        }
    }
}
