// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioFileTypes.swift
//  Pocket Tandas
//
//  Central definition of which files the browser shows and treats as audio /
//  playlists.
//

import Foundation
import UniformTypeIdentifiers

enum AudioFileTypes {
    static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    /// Common audio extensions. AVFoundation can decode most of these on iOS;
    /// unsupported ones (e.g. ogg/opus) still list but may fail to play/scan,
    /// which is handled gracefully downstream.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf",
        "alac", "flac", "m4b", "mp4", "aifc", "ogg", "opus"
    ]

    static func isPlaylist(_ url: URL) -> Bool {
        playlistExtensions.contains(url.pathExtension.lowercased())
    }

    static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .audio)
        }
        return false
    }
}
