// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PCMAssetReader.swift
//  Pocket Tandas
//
//  Three things in this app read an asset front to back as Float32 PCM — the
//  media decoder that feeds playback, the BPM analyser, and the hum scout — and
//  all three used to open the reader and unpack each block themselves. The
//  settings dictionary was written out three times, and so was the
//  CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer incantation, which is
//  twenty lines with one rule in it that matters:
//
//      the AudioBufferList's pointers are owned by the CMBlockBuffer, and the
//      block buffer has to outlive every read through them.
//
//  That rule is what this file exists for. `withAudioBuffers` scopes the block
//  buffer to the call, so the pointers cannot outlive it by construction rather
//  than by each caller remembering `withExtendedLifetime`.
//
//  What the three do with the samples is genuinely different — one copies frame
//  ranges into deinterleaved chunks, one downmixes, one sums to mono — so that
//  stays with each of them. Only the opening and the unpacking are shared.
//

import Foundation
import AVFoundation

enum PCMAssetReader {

    /// How the reader should lay out what it delivers.
    enum Layout {
        /// One buffer, samples interleaved across channels.
        case interleaved
        /// One buffer per channel.
        case deinterleaved
    }

    enum ReaderError: Error {
        case noAudioTrack
        case readerFailed
    }

    /// A reader delivering `track` as Float32 PCM, plus the output to pull from.
    /// Started — the caller reads with `copyNextSampleBuffer` until it returns nil.
    ///
    /// `channels` is nil to keep the track's own count, which is what a caller
    /// that downmixes for itself wants; the reader does the downmix when it is
    /// given a number.
    static func make(track: AVAssetTrack,
                     of asset: AVURLAsset,
                     sampleRate: Double,
                     channels: Int?,
                     layout: Layout) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: layout == .deinterleaved,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
        ]
        if let channels { settings[AVNumberOfChannelsKey] = channels }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        // Every caller copies the block it is handed before asking for the next.
        output.alwaysCopiesSampleData = false

        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else {
            throw ReaderError.readerFailed
        }
        reader.add(output)
        return (reader, output)
    }

    /// The same, finding the asset's first audio track first. Blocks — see
    /// SynchronousAssetLoading.
    static func make(assetURL: URL,
                     sampleRate: Double,
                     channels: Int?,
                     layout: Layout) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: assetURL)
        guard let track = try asset.firstAudioTrackSynchronously() else { throw ReaderError.noAudioTrack }
        return try make(track: track, of: asset, sampleRate: sampleRate, channels: channels, layout: layout)
    }

    /// Run `body` over one sample buffer's audio, with the backing CMBlockBuffer
    /// alive for exactly that long.
    ///
    /// `maximumBuffers` is 1 for interleaved audio and the channel count for
    /// deinterleaved. Returns nil — without calling `body` — when the buffer
    /// carries no readable audio, which is the "skip this block" answer all three
    /// callers already wanted.
    static func withAudioBuffers<R>(_ sample: CMSampleBuffer,
                                    maximumBuffers: Int,
                                    _ body: (UnsafeMutableAudioBufferListPointer,
                                             AudioStreamBasicDescription) throws -> R) rethrows -> R? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mChannelsPerFrame > 0, maximumBuffers > 0 else { return nil }

        let list = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        defer { free(list.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, list.count > 0 else { return nil }

        // The list's pointers belong to `blockBuffer`. Holding it across the call
        // is the whole point of this function.
        return try withExtendedLifetime(blockBuffer) { try body(list, asbd) }
    }

    /// Frames in one buffer of Float32 samples, from its byte count rather than
    /// from `CMSampleBufferGetNumSamples` — it is the block about to be read, so
    /// it is what bounds the read.
    static func frameCount(of buffer: AudioBuffer, channels: Int) -> Int {
        guard channels > 0 else { return 0 }
        return Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }
}
