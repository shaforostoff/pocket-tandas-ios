// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaLibraryImporter.swift
//  Pocket Tandas
//
//  Music-library access gate. Tracks are now played by reference (AVAssetReader
//  streaming from `ipod-library://`, see MediaTrackDecoder) rather than copied into
//  the sandbox, so this is just the authorization helper the Music browser and the
//  remote receiver call before querying the library.
//

import Foundation
import MediaPlayer

enum MediaLibraryImporter {
    /// Ask for Music-library access (required before MPMediaQuery returns content).
    /// Returns immediately when already authorized; otherwise prompts once.
    static func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        if MPMediaLibrary.authorizationStatus() == .authorized { return .authorized }
        return await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
        }
    }
}
