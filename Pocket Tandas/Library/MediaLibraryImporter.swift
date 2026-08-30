// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaLibraryImporter.swift
//  Pocket Tandas
//
//  Imports tracks picked from the device Music library into the app sandbox so the
//  playback engine — which reads files with AVAudioFile, and can't open the
//  library's ipod-library:// URLs — can play them.
//
//  Apple Music / DRM items have no `assetURL` and are skipped. Non-DRM items are
//  exported to a real .m4a under Application Support. A passthrough export is tried
//  first: it's lossless, fast, and preserves the source's embedded tags (BPM,
//  ReplayGain, …) that the metadata scan and engine rely on; AppleM4A re-encoding
//  is the fallback for sources passthrough can't wrap as .m4a.
//

import Foundation
import AVFoundation
import MediaPlayer

enum MediaLibraryImporter {

    /// Outcome of an import batch — enough to enqueue the winners and, later,
    /// surface how many picks were skipped (DRM) or failed to export.
    struct ImportSummary {
        var imported: [URL] = []
        var skippedProtected = 0   // DRM / no asset URL — can't be read at all
        var failed = 0             // export error
    }

    enum ImportError: Error { case noSession, exportFailed }

    // MARK: - Authorization

    /// Ask for Music-library access (required before the picker shows content).
    /// Returns immediately when already authorized; otherwise prompts once.
    static func requestAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        if MPMediaLibrary.authorizationStatus() == .authorized { return .authorized }
        return await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    // MARK: - Import

    /// Export every non-DRM item to a sandbox file. Idempotent: an item already
    /// exported (matched by persistent id in the filename) reuses its file rather
    /// than re-exporting, so re-adding a track is cheap.
    static func importItems(_ items: [MPMediaItem]) async -> ImportSummary {
        var summary = ImportSummary()
        for item in items {
            guard let assetURL = item.assetURL else { summary.skippedProtected += 1; continue }
            let outURL = destination(for: item)
            if FileManager.default.fileExists(atPath: outURL.path) {
                summary.imported.append(outURL)
                continue
            }
            do {
                try await export(assetURL: assetURL, to: outURL)
                summary.imported.append(outURL)
            } catch {
                summary.failed += 1
            }
        }
        return summary
    }

    // MARK: - Export

    private static let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]

    private static func export(assetURL: URL, to outURL: URL) async throws {
        let asset = AVURLAsset(url: assetURL)
        var lastError: Error?
        for preset in presets {
            try? FileManager.default.removeItem(at: outURL)   // clear any partial output
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                lastError = ImportError.noSession
                continue
            }
            session.outputURL = outURL
            session.outputFileType = .m4a
            await withCheckedContinuation { cont in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status == .completed { return }
            lastError = session.error ?? ImportError.exportFailed
        }
        try? FileManager.default.removeItem(at: outURL)
        throw lastError ?? ImportError.exportFailed
    }

    // MARK: - Paths

    /// App-sandbox directory holding exported library copies. Under Application
    /// Support so the files persist across launches — the play queue stores their
    /// paths and resolves them again at restore.
    static var importsDirectory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("MusicLibraryImports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A readable, collision-free filename: "Artist - Title [persistentID].m4a".
    /// The persistent-id suffix makes it unique and lets a re-add find the existing
    /// file; the readable prefix is the queue's fallback label if a tag scan misses.
    private static func destination(for item: MPMediaItem) -> URL {
        let artist = sanitized(item.artist, fallback: "Unknown Artist")
        let title = sanitized(item.title, fallback: "Unknown Title")
        let name = "\(artist) - \(title) [\(item.persistentID)].m4a"
        return importsDirectory.appendingPathComponent(name)
    }

    private static func sanitized(_ value: String?, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = (value ?? "")
            .components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
