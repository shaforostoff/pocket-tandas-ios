// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackAnalyzer.swift
//  Pocket Tandas
//
//  Decodes one track front to back and hands the audio to `PTBPMAnalyzer`. The
//  measurement itself is bpmcore's (see Analysis/PROVENANCE.md); everything here
//  is the read.
//
//  `analyze` is synchronous and blocking — TrackAnalysisQueue runs it on its own
//  dispatch queue, several tracks at a time. It does not touch shared state, so
//  those runs are independent; `isCancelled` is polled between sample buffers and
//  again inside the core, and is the only way out early.
//

import Foundation
import AVFoundation

enum TrackAnalyzer {
    enum Outcome {
        /// The track was read and the core had its say. `result` may be empty —
        /// that is an answer ("nothing measurable here") and gets recorded, so
        /// the track isn't decoded again on the next visit.
        case measured(TrackAnalysisResult)
        /// Nothing was read: no audio track, an unreadable file, a folder whose
        /// permission has lapsed. Deliberately NOT recorded — most of those are
        /// temporary, and a track written off for good over one bad read would
        /// never be measured again.
        case failed
        case cancelled
    }

    /// The rate the decoder is asked to deliver.
    ///
    /// The core's analysis geometry is fixed in seconds, but its window still has
    /// to be a power of two, so only the model rate (22050) times a power of two
    /// reproduces exactly the analysis the rhythm model was fitted at. 44.1 kHz
    /// is one of those, is what almost every tango transfer already is — so the
    /// common case converts nothing — and settles every other rate here, with
    /// AVFoundation's converter, rather than leaving each file to be analysed on
    /// its own time base.
    static let sampleRate: Double = 44_100

    /// Longest stretch of one track read into memory.
    ///
    /// The core buffers the whole side rather than streaming it — the onset
    /// envelope has to be normalised by the track's overall level, which is not
    /// known until the end — at roughly 5 MB a minute, and `concurrency` of these
    /// run at once. The core's own cap is fifteen minutes, which is there to bound
    /// a mis-tagged file rather than to describe any music; several of those at
    /// once is a few hundred MB on a phone, which is worth not risking.
    ///
    /// Six minutes covers every tango side twice over, so in practice this only
    /// ever truncates a DJ set or a mis-tagged file — and the tempo of its first
    /// six minutes is a better answer for one of those than no answer at all.
    static let maximumDuration: TimeInterval = 360

    /// Read `url` and measure it. See the type's note on blocking.
    static func analyze(url: URL, isCancelled: @escaping () -> Bool) -> Outcome {
        let asset = AVURLAsset(url: url)
        guard let track = try? asset.firstAudioTrackSynchronously() else { return .failed }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            // Interleaved, which is the layout the core takes: it downmixes to
            // mono on the way in, so the channel count is its business and not
            // something to pin here.
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false   // every block is consumed immediately

        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else { return .failed }
        reader.add(output)
        guard reader.startReading() else { return .failed }

        var analyzer: PTBPMAnalyzer?
        var framesRead = 0
        let frameLimit = Int(maximumDuration * sampleRate)
        /// Set when a length cap stopped the read, so the `.cancelled` status that
        /// `cancelReading` leaves behind can be told from a real one.
        var reachedLimit = false

        while reader.status == .reading {
            if isCancelled() {
                reader.cancelReading()
                return .cancelled
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                framesRead += feed(sample, into: &analyzer)
            }
            if framesRead >= frameLimit || analyzer?.isFull == true {
                reachedLimit = true
                reader.cancelReading()
            }
        }

        switch reader.status {
        case .completed: break
        case .cancelled where reachedLimit: break
        default: return .failed
        }

        guard let analyzer else { return .failed }   // no readable audio at all
        guard let measurement = analyzer.finishUnlessCancelled({ isCancelled() }) else { return .cancelled }
        return .measured(result(from: measurement))
    }

    /// Hand one decoded block to the analyser, building it on the first block —
    /// the format the reader actually produced is the one to trust, rather than
    /// what was asked for. Returns the frames handed over, which is what the
    /// length cap counts.
    private static func feed(_ sample: CMSampleBuffer, into analyzer: inout PTBPMAnalyzer?) -> Int {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mChannelsPerFrame > 0 else { return 0 }

        let list = AudioBufferList.allocate(maximumBuffers: 1)   // interleaved: one buffer
        defer { free(list.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 1),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let buffer = list.first, let data = buffer.mData else { return 0 }

        // Frames from the byte count rather than CMSampleBufferGetNumSamples:
        // it is the block we are about to read, so it is what bounds the read.
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return 0 }

        if analyzer == nil {
            analyzer = PTBPMAnalyzer(sampleRate: asbd.mSampleRate, channels: UInt(channels))
        }

        // The list's pointers are owned by `blockBuffer`; keep it alive across the
        // copy rather than trusting ARC not to release it early.
        withExtendedLifetime(blockBuffer) {
            analyzer?.addInterleavedFloats(data.assumingMemoryBound(to: Float.self),
                                           frameCount: UInt(frames))
        }
        return frames
    }

    private static func result(from measurement: PTBPMMeasurement) -> TrackAnalysisResult {
        guard measurement.measured else { return TrackAnalysisResult() }
        return TrackAnalysisResult(bpm: measurement.bpm > 0 ? measurement.bpm : nil,
                                   genre: AnalyzedRhythm.genre(for: measurement.rhythm),
                                   confidence: measurement.confidence)
    }
}
