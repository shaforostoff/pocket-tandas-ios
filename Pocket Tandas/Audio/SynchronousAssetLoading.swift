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
        try loadSynchronously { try await self.loadTracks(withMediaType: .audio) }.first
    }

    /// The asset's duration in seconds, or 0 where it cannot be read. Same
    /// blocking contract as above.
    ///
    /// Worth one load: the analysis buffers the whole side, and a collector told
    /// the length reserves for it instead of outgrowing a default and doubling.
    func durationSecondsSynchronously() -> TimeInterval {
        guard let duration = try? loadSynchronously({ try await self.load(.duration) }) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Run one `load` to completion on the calling thread. The reference box is
    /// what hands the result back across the semaphore without tripping "mutation
    /// of captured var"; the wait/signal pair is the happens-before that makes the
    /// unchecked Sendable sound.
    private func loadSynchronously<T: Sendable>(_ load: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await load()) }
            catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

/// Hands one `load`'s result back across the semaphore without tripping
/// "mutation of captured var"; the wait/signal pair is the happens-before that
/// makes the unchecked Sendable sound. A file-scope type because a generic one
/// cannot be nested in a generic function.
private final class ResultBox<V>: @unchecked Sendable {
    var result: Result<V, Error>?
}
