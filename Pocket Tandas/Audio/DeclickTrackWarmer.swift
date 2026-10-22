// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  DeclickTrackWarmer.swift
//  Pocket Tandas
//
//  Declick's warm start for the track that is starting, so the first seconds of
//  a record are repaired with the carpet key and crackle floor the core has once
//  it has heard them, rather than with empty history.
//
//  The core's slow state starts empty at the first sample, so a loud opening can
//  open the key and take a few frames for the floor (see DSP/declick_core.h,
//  `Channel::beginWarm`). A file player can read ahead: the opening of the track
//  is decoded on a worker queue, run through a throwaway channel per channel of
//  the unit, and what that learned goes to `PTDeclickProcessor.adoptWarm`, which
//  re-warms the live cores from it at the top of the next render call. The decode
//  runs far faster than playback, so it lands within a few hundred milliseconds
//  of the record starting; adopting a little late is what the core documents as
//  starting "with the key and the ceiling of those seconds, standing still for as
//  long as they did".
//
//  Deliberately per track, like DehumTrackScout, and the same job the
//  foobar2000 component's warm hold does in the shape this app can do it.
//

import Foundation
import AVFoundation

final class DeclickTrackWarmer {

    private let queue = DispatchQueue(label: "tandas.declickwarm", qos: .userInitiated)

    /// Bumped on the main thread whenever a pass is started or cancelled, so a
    /// superseded worker's result is dropped rather than adopted.
    private var token = 0

    /// Shared with the worker so a cancel reaches it between sample buffers and
    /// can stop the reader itself.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var reader: AVAssetReader?

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func adopt(_ reader: AVAssetReader) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.reader = reader
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let reader = self.reader
            lock.unlock()
            reader?.cancelReading()
        }
    }

    private var job: Job?

    /// Warm the unit for the record at `url`. `onWarm` runs on the main thread
    /// with a finished pass; a pass superseded or cancelled never calls it. Any
    /// pass already running is cancelled first.
    func warm(url: URL, with warmer: PTDeclickWarmer, onWarm: @escaping (PTDeclickWarmer) -> Void) {
        cancel()
        token += 1
        let token = self.token
        let job = Job()
        self.job = job

        queue.async { [weak self] in
            let ok = Self.run(url: url, warmer: warmer, job: job)
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                self.job = nil
                if ok { onWarm(warmer) }
            }
        }
    }

    func cancel() {
        token += 1
        job?.cancel()
        job = nil
    }

    /// Reads `warmer.seconds` of the opening of `url` at the unit's own rate and
    /// channel count and feeds it in. False for anything unreadable, too short to
    /// warm, or cancelled — the live unit then simply starts cold, as before.
    private static func run(url: URL, warmer: PTDeclickWarmer, job: Job) -> Bool {
        let channels = warmer.channelCount
        guard channels > 0,
              let (reader, output) = try? PCMAssetReader.make(assetURL: url, sampleRate: warmer.sampleRate,
                                                              channels: channels, layout: .deinterleaved),
              !job.isCancelled, job.adopt(reader), reader.startReading() else { return false }

        let wanted = Int(warmer.seconds * warmer.sampleRate)
        var read = 0
        while reader.status == .reading, read < wanted, !job.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                read += feed(sample, to: warmer, channels: channels, limit: wanted - read)
            }
        }
        let completed = reader.status == .reading || reader.status == .completed
        reader.cancelReading()

        // A track shorter than the warm length is warmed over what it has: the
        // core's own contract is that the pass is whatever was pushed.
        guard completed, !job.isCancelled, read > 0 else { return false }
        return warmer.finish()
    }

    private static func feed(_ sample: CMSampleBuffer, to warmer: PTDeclickWarmer,
                             channels: Int, limit: Int) -> Int {
        let frames = min(CMSampleBufferGetNumSamples(sample), limit)
        guard frames > 0 else { return 0 }

        return PCMAssetReader.withAudioBuffers(sample, maximumBuffers: channels) { list, _ -> Int in
            guard list.count == channels else { return 0 }
            var count = frames
            var pointers = [UnsafePointer<Float>]()
            pointers.reserveCapacity(channels)
            for buffer in list {
                guard let data = buffer.mData else { return 0 }
                count = min(count, PCMAssetReader.frameCount(of: buffer, channels: 1))
                pointers.append(UnsafePointer(data.assumingMemoryBound(to: Float.self)))
            }
            guard count > 0 else { return 0 }
            pointers.withUnsafeBufferPointer { warmer.feed($0.baseAddress!, channelCount: channels, frameCount: count) }
            return count
        } ?? 0
    }
}
