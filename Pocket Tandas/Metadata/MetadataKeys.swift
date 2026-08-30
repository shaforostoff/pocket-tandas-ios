// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataKeys.swift
//  Pocket Tandas
//
//  Ordered metadata identifiers to try per field. Common identifiers are tried
//  where AVFoundation already unifies ID3/iTunes tags; BPM and comment have no
//  common key, so they use format-specific identifiers.
//

import AVFoundation

enum MetadataKeys {
    static let title: [AVMetadataIdentifier] = [
        .commonIdentifierTitle,
        .id3MetadataTitleDescription,
        .iTunesMetadataSongName
    ]

    static let artist: [AVMetadataIdentifier] = [
        .commonIdentifierArtist,
        .iTunesMetadataArtist
    ]

    static let genre: [AVMetadataIdentifier] = [
        .id3MetadataContentType,
        .iTunesMetadataUserGenre,
        .commonIdentifierType
    ]

    static let date: [AVMetadataIdentifier] = [
        .id3MetadataRecordingTime,
        .commonIdentifierCreationDate,
        .iTunesMetadataReleaseDate,
        .id3MetadataYear
    ]

    static let comment: [AVMetadataIdentifier] = [
        .id3MetadataComments,
        .iTunesMetadataUserComment
    ]

    static let bpm: [AVMetadataIdentifier] = [
        .id3MetadataBeatsPerMinute,
        .iTunesMetadataBeatsPerMin,
        // TangoTunes (and some other taggers) store BPM in a freeform iTunes
        // atom (----:com.apple.iTunes:BPM) rather than the standard `tmpo`.
        AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.BPM")
    ]
}
