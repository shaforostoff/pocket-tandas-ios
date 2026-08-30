// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaTrackDecoder.swift
//  Pocket Tandas
//
//  Decodes a non-DRM Music-library asset (an `ipod-library://` URL) into a single
//  PCM buffer the engine schedules with `scheduleBuffer`. The whole track is read
//  into one AVAudioPCMBuffer: tango tracks are short, and one buffer means exactly
//  one `.dataPlayedBack` completion (== end of track), matching the engine's file
//  contract. Media items are never preloaded gaplessly, so there is no need to
//  stream/refill — one buffer is simplest and correct.
//
//  `decode` is synchronous and blocking — call it off the main thread (the engine
//  runs it on a dedicated serial queue). `cancel()` is safe from any thread and
//  makes an in-flight decode return via `.cancelled`.
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

    enum DecodeError: Error { case noAudioTrack, readerFailed, allocFailed, cancelled }

    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false

    /// Stop an in-flight decode. The reading loop exits promptly and `decode`
    /// throws `.cancelled`.
    func cancel() {
        lock.lock()
        cancelled = true
        reader?.cancelReading()
        lock.unlock()
    }

    func decode(assetURL: URL, expectedDuration: TimeInterval) throws -> (AVAudioPCMBuffer, AVAudioFormat) {
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

        // Size from the known duration + 1 s slack; appends are clamped so a short
        // estimate can never overrun.
        let capacity = AVAudioFrameCount((max(1.0, expectedDuration) + 1.0) * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DecodeError.allocFailed
        }
        buffer.frameLength = 0

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                append(sample, to: buffer)
            }
        }

        switch reader.status {
        case .completed: return (buffer, format)
        case .cancelled: throw DecodeError.cancelled
        default:         throw DecodeError.readerFailed
        }
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

    /// Copy one sample buffer's deinterleaved Float32 channels into `pcm` at its
    /// running frameLength, clamped to capacity.
    private func append(_ sample: CMSampleBuffer, to pcm: AVAudioPCMBuffer) {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let channelData = pcm.floatChannelData else { return }
        let channels = Int(pcm.format.channelCount)
        let dstOffset = Int(pcm.frameLength)
        let room = Int(pcm.frameCapacity) - dstOffset
        guard room > 0 else { return }
        let copyFrames = min(frames, room)

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
        guard status == noErr else { return }

        let srcCount = list.count
        for ch in 0..<channels {
            // Deinterleaved: one source buffer per channel. A mono source delivered
            // as a single buffer is mirrored across both output channels.
            let src = list[min(ch, srcCount - 1)]
            guard let mData = src.mData else { continue }
            let srcFloats = mData.assumingMemoryBound(to: Float.self)
            (channelData[ch] + dstOffset).update(from: srcFloats, count: copyFrames)
        }
        pcm.frameLength = AVAudioFrameCount(dstOffset + copyFrames)
    }
}
