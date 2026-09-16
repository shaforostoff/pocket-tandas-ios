// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SynchronousAssetLoading.swift
//  Pocket Tandas
//
//  `AVAsset.loadTracks` is async; the two things in this app that read an asset
//  front to back — the media decoder that feeds playback, and the BPM analyser —
//  are both synchronous loops on a dedicated dispatch queue. This is the one
//  bridge between the two, rather than one each.
//
//  Blocking here is safe BECAUSE of that: both callers run on a private queue,
//  never on a Swift Concurrency executor thread, so the wait cannot starve the
//  cooperative pool.
//

import Foundation
import AVFoundation

extension AVURLAsset {
    /// The asset's first audio track, or nil if it has none. Blocks the calling
    /// thread — never call it on the main thread or from an async context.
    func firstAudioTrackSynchronously() throws -> AVAssetTrack? {
        // Reference box so the load task hands its result back across the
        // semaphore without tripping "mutation of captured var"; the wait/signal
        // pair is the happens-before that makes the unchecked Sendable sound.
        final class Box: @unchecked Sendable { var result: Result<[AVAssetTrack], Error>? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await self.loadTracks(withMediaType: .audio)) }
            catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result?.get().first
    }
}
