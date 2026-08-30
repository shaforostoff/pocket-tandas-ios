// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataExtractor.swift
//  Pocket Tandas
//
//  Thin AVFoundation adapter: reads a file's metadata items and maps them to
//  ExtractedMetadata, delegating the date/BPM rules to MetadataParsing. Returns
//  an empty value (not nil) when nothing is found, so the scan still records a
//  cache entry and the file isn't rescanned.
//

import Foundation
import AVFoundation

enum MetadataExtractor {
    static func extract(url: URL) async -> ExtractedMetadata {
        let asset = AVURLAsset(url: url)

        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) { items += common }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let formatItems = try? await asset.loadMetadata(for: format) {
                    items += formatItems
                }
            }
        }
        guard !items.isEmpty else { return ExtractedMetadata() }

        let dateField = await firstString(items, MetadataKeys.date)
        let comment = await firstString(items, MetadataKeys.comment)
        let resolved = MetadataParsing.resolveDate(dateField: dateField, commentField: comment)

        return ExtractedMetadata(
            title: await firstString(items, MetadataKeys.title),
            artist: await firstString(items, MetadataKeys.artist),
            genre: await firstString(items, MetadataKeys.genre),
            dateText: resolved.dateText,
            year: resolved.year,
            bpm: MetadataParsing.parseBPM(await firstString(items, MetadataKeys.bpm)),
            trackGainDB: MetadataParsing.parseReplayGainGain(await firstString(items, MetadataKeys.replayGainTrack))
        )
    }

    private static func firstString(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) async -> String? {
        for id in ids {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                if let s = try? await item.load(.stringValue) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                if let n = try? await item.load(.numberValue) {
                    return n.stringValue
                }
            }
        }
        return nil
    }
}
