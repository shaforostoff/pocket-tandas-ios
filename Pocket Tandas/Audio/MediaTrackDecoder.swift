// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaTrackDecoder.swift
//  Pocket Tandas
//
//  Decodes a non-DRM Music-library asset (an `ipod-library://` URL) into a STREAM
//  of fixed-length PCM chunks the engine schedules back-to-back with
//  `scheduleBuffer`. Consecutive scheduled buffers play with no gap, so the track
//  still sounds like one continuous schedule — but only a few seconds of audio is
//  ever resident instead of the whole track (Float32/44.1k/stereo costs ~0.34 MB
//  per second, so a 10-minute track as one buffer was over 200 MB).
//
//  The decoder runs ahead of playback by at most `maxChunksInFlight` chunks: it
//  parks on a semaphore that the consumer signals (via `releaseChunk`) as each
//  delivered chunk finishes playing. Peak residency is therefore the in-flight
//  chunks plus the one being filled.
//
//  The consumer needs to know which buffer ENDS the track, and that isn't knowable
//  until the reader stops producing — so one chunk is always held back and handed
//  over with `isLast: true` once the read loop is done.
//
//  `decode` is synchronous and blocking — call it off the main thread (the engine
//  runs it on a dedicated serial queue). `cancel()` is safe from any thread: it
//  stops the reader AND unparks a decode waiting for a playback slot, so an
//  in-flight decode returns promptly via `.cancelled`.
//
//  AVAssetReader can read non-DRM library assets; DRM/cloud items have no readable
//  asset URL and are filtered out before they ever reach here.
//

import Foundation
import AVFoundation

final class MediaTrackDecoder {
    /// Canonical engine format: deinterleaved Float32, 44.1 kHz stereo. The
    /// reader's converter maps any source rate/layout onto this, so every media
    /// item connects the player node with the same format.
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 44_100,
                                            channels: 2,
                                            interleaved: false)!

    /// Length of one decoded chunk (~3.4 MB at the format above). Long enough that
    /// the decode thread wakes only a handful of times per track, short enough that
    /// resident audio stays a few MB.
    static let chunkDuration: TimeInterval = 10

    /// How far the decoder may run ahead of playback, in delivered-but-not-yet-
    /// played chunks. Two keeps the player fed across a chunk boundary while
    /// holding at most three chunks (two queued plus the one being filled).
    static let maxChunksInFlight = 2

    enum DecodeError: Error { case noAudioTrack, readerFailed, allocFailed, emptyTrack, cancelled }

    /// Receives each decoded chunk in order. `isLast` marks the final one — the
    /// consumer hangs its end-of-track handling off that buffer. Called on the
    /// decoder's own (caller's) thread.
    typealias ChunkHandler = (_ buffer: AVAudioPCMBuffer, _ isLast: Bool) -> Void

    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false

    /// Playback slots: one is taken by each hand-off, returned by `releaseChunk`.
    private let slots = DispatchSemaphore(value: MediaTrackDecoder.maxChunksInFlight)

    /// Stop an in-flight decode. The reading loop exits promptly — including from
    /// a park on the slot semaphore — and `decode` throws `.cancelled`.
    func cancel() {
        lock.lock()
        cancelled = true
        reader?.cancelReading()
        lock.unlock()
        slots.signal()   // unpark a decode waiting for playback that will never come
    }

    /// Return the slot held by a delivered chunk, once it has finished playing.
    /// Safe from any thread (the engine calls it from a schedule completion).
    func releaseChunk() {
        slots.signal()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Read the asset start to finish, handing `onChunk` one buffer at a time.
    /// Returns once the whole track has been delivered; throws if the read failed
    /// or the decode was cancelled.
    func decode(assetURL: URL, onChunk: ChunkHandler) throws {
        let asset = AVURLAsset(url: assetURL)
        // `loadTracks` is async; bridge it back into this synchronous, off-main
        // decode with a semaphore. Safe to block: we run on a private dispatch
        // queue, never on a Swift Concurrency executor thread.
        guard let track = try loadFirstAudioTrack(of: asset) else {
            throw DecodeError.noAudioTrack
        }

        let format = Self.outputFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false   // we copy each block immediately

        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else {
            throw DecodeError.readerFailed
        }
        reader.add(output)

        lock.lock()
        if cancelled { lock.unlock(); throw DecodeError.cancelled }
        self.reader = reader
        lock.unlock()

        guard reader.startReading() else { throw DecodeError.readerFailed }

        let chunkFrames = AVAudioFrameCount(Self.chunkDuration * format.sampleRate)

        /// Take a playback slot, then hand the chunk over. Parks while the consumer
        /// is still working through what it already has.
        func handOff(_ buffer: AVAudioPCMBuffer, isLast: Bool) throws {
            slots.wait()
            if isCancelled { throw DecodeError.cancelled }
            onChunk(buffer, isLast)
        }

        // `held` is the completed chunk waiting to learn whether another follows it.
        var held: AVAudioPCMBuffer?
        var current = try makeChunk(frames: chunkFrames, format: format)

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            try autoreleasepool {
                // Only the flush below can know it holds the final chunk, so
                // everything `consume` rolls over is delivered as non-last.
                try consume(sample, into: &current, held: &held, frames: chunkFrames,
                            format: format, handOff: { try handOff($0, isLast: false) })
            }
        }

        switch reader.status {
        case .completed: break
        case .cancelled: throw DecodeError.cancelled
        default:         throw DecodeError.readerFailed
        }

        // Flush: whichever buffer holds the tail of the track is the last one.
        if current.frameLength > 0 {
            if let held { try handOff(held, isLast: false) }
            try handOff(current, isLast: true)
        } else if let held {
            try handOff(held, isLast: true)
        } else {
            throw DecodeError.emptyTrack
        }
    }

    /// Copy one sample buffer into the chunk stream, rolling over to a fresh chunk
    /// (and handing the previous one off) whenever `current` fills up. A sample
    /// buffer straddling a boundary is split rather than truncated.
    private func consume(_ sample: CMSampleBuffer,
                         into current: inout AVAudioPCMBuffer,
                         held: inout AVAudioPCMBuffer?,
                         frames chunkFrames: AVAudioFrameCount,
                         format: AVAudioFormat,
                         handOff: (AVAudioPCMBuffer) throws -> Void) throws {
        let totalFrames = CMSampleBufferGetNumSamples(sample)
        guard totalFrames > 0 else { return }
        let channels = Int(format.channelCount)

        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(list.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, list.count > 0 else { return }

        // The list's pointers are owned by `blockBuffer`; keep it alive across
        // every copy below rather than trusting ARC not to release it early.
        try withExtendedLifetime(blockBuffer) {
            var srcOffset = 0
            while srcOffset < totalFrames {
                let copied = copyFrames(from: list, srcOffset: srcOffset,
                                        frames: totalFrames - srcOffset, to: current)
                guard copied > 0 else { return }   // no room and no progress possible
                srcOffset += copied
                if current.frameLength == current.frameCapacity {
                    if let ready = held { try handOff(ready) }
                    held = current
                    current = try makeChunk(frames: chunkFrames, format: format)
                }
            }
        }
    }

    /// Copy up to `frames` frames, starting `srcOffset` frames in, from the
    /// deinterleaved Float32 `list` into `pcm` at its running frameLength. Returns
    /// the number of frames actually copied (clamped to the chunk's free space).
    private func copyFrames(from list: UnsafeMutableAudioBufferListPointer,
                            srcOffset: Int, frames: Int, to pcm: AVAudioPCMBuffer) -> Int {
        guard frames > 0, let channelData = pcm.floatChannelData else { return 0 }
        let channels = Int(pcm.format.channelCount)
        let dstOffset = Int(pcm.frameLength)
        let room = Int(pcm.frameCapacity) - dstOffset
        guard room > 0 else { return 0 }
        let count = min(frames, room)

        let srcCount = list.count
        for ch in 0..<channels {
            // Deinterleaved: one source buffer per channel. A mono source delivered
            // as a single buffer is mirrored across both output channels.
            let src = list[min(ch, srcCount - 1)]
            guard let mData = src.mData else { continue }
            let srcFloats = mData.assumingMemoryBound(to: Float.self)
            (channelData[ch] + dstOffset).update(from: srcFloats + srcOffset, count: count)
        }
        pcm.frameLength = AVAudioFrameCount(dstOffset + count)
        return count
    }

    private func makeChunk(frames: AVAudioFrameCount, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw DecodeError.allocFailed
        }
        buffer.frameLength = 0
        return buffer
    }

    /// Load the first audio track, bridging `AVAsset.loadTracks` (async) into the
    /// synchronous `decode`. Blocking is safe here — `decode` runs on a dedicated
    /// dispatch queue, so the wait can't starve the concurrency cooperative pool.
    private func loadFirstAudioTrack(of asset: AVURLAsset) throws -> AVAssetTrack? {
        // Reference box so the load task hands its result back across the
        // semaphore without tripping "mutation of captured var"; the wait/signal
        // pair is the happens-before that makes the unchecked Sendable sound.
        final class Box: @unchecked Sendable { var result: Result<[AVAssetTrack], Error>? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await asset.loadTracks(withMediaType: .audio)) }
            catch { box.result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result?.get().first
    }
}
