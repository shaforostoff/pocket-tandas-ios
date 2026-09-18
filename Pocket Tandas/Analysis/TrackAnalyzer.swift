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
    /// reproduces exactly the analysis the rhythm model was fitted at. Asking for
    /// the model rate itself settles every file here, with AVFoundation's
    /// converter, rather than leaving each one to be analysed on its own time
    /// base — and it is the cheapest of those rates to then analyse.
    ///
    /// It used to be 44.1 kHz, on the reasoning that almost every tango transfer
    /// already is one and the common case would convert nothing. What that missed
    /// is that a rate the core does not have to resample is a rate it BUFFERS at:
    /// 44.1 kHz held the whole side at 44.1 kHz, twice the memory and a quarter
    /// more work, to reach the same answer. The same tango side measured at both:
    ///
    ///     44100 Hz   bpm=127.860  beat=128.506  meter=2  tango  conf=0.9998
    ///     22050 Hz   bpm=127.861  beat=128.508  meter=2  tango  conf=0.9998
    ///
    /// — 0.001 BPM apart, for half the memory (28.6 MB against 14.3 MB on that
    /// side) and about a quarter less time.
    static let sampleRate: Double = 22_050

    /// Longest stretch of one track read into memory.
    ///
    /// The core buffers the whole side rather than streaming it — the onset
    /// envelope has to be normalised by the track's overall level, which is not
    /// known until the end — at 5.3 MB a minute at `sampleRate`, and
    /// `concurrency` of these run at once. The core's own cap is fifteen minutes,
    /// which is there to bound a mis-tagged file rather than to describe any
    /// music; several of those at once is a few hundred MB on a phone, which is
    /// worth not risking.
    ///
    /// Six minutes covers every tango side twice over, so in practice this only
    /// ever truncates a DJ set or a mis-tagged file — and the tempo of its first
    /// six minutes is a better answer for one of those than no answer at all.
    ///
    /// This is a cap on what is READ, not on what is reserved: the buffer is
    /// sized from the track's own length (see `analyze`), so an ordinary side
    /// costs what it is rather than what the longest one might be.
    static let maximumDuration: TimeInterval = 360

    /// Read `url` and measure it. See the type's note on blocking.
    static func analyze(url: URL, isCancelled: @escaping () -> Bool) -> Outcome {
        let asset = AVURLAsset(url: url)
        guard let track = try? asset.firstAudioTrackSynchronously() else { return .failed }

        // Told up front, the collector reserves for this side instead of growing
        // into a default and doubling — a copy that has both allocations resident
        // at once. Capped at what will actually be read, so a mis-tagged
        // three-hour file reserves six minutes and not three hours. Unreadable
        // duration reads 0, which the core takes as "not told".
        let expectedSeconds = min(asset.durationSecondsSynchronously(), maximumDuration)

        // Interleaved, which is the layout the core takes, and at the track's own
        // channel count: it downmixes on the way in, so that is its business and
        // not something to pin here.
        guard let (reader, output) = try? PCMAssetReader.make(track: track, of: asset,
                                                              sampleRate: sampleRate,
                                                              channels: nil, layout: .interleaved),
              reader.startReading() else { return .failed }

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
                framesRead += feed(sample, into: &analyzer, expectedSeconds: expectedSeconds)
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
    private static func feed(_ sample: CMSampleBuffer, into analyzer: inout PTBPMAnalyzer?,
                             expectedSeconds: TimeInterval) -> Int {
        PCMAssetReader.withAudioBuffers(sample, maximumBuffers: 1) { list, asbd -> Int in
            guard let buffer = list.first, let data = buffer.mData else { return 0 }
            let channels = Int(asbd.mChannelsPerFrame)
            let frames = PCMAssetReader.frameCount(of: buffer, channels: channels)
            guard frames > 0 else { return 0 }

            if analyzer == nil {
                analyzer = PTBPMAnalyzer(sampleRate: asbd.mSampleRate, channels: UInt(channels),
                                         expectedSeconds: expectedSeconds)
            }
            analyzer?.addInterleavedFloats(data.assumingMemoryBound(to: Float.self),
                                           frameCount: UInt(frames))
            return frames
        } ?? 0
    }

    private static func result(from measurement: PTBPMMeasurement) -> TrackAnalysisResult {
        guard measurement.measured else { return TrackAnalysisResult() }
        return TrackAnalysisResult(bpm: measurement.bpm > 0 ? measurement.bpm : nil,
                                   genre: AnalyzedRhythm.genre(for: measurement.rhythm),
                                   confidence: measurement.confidence)
    }
}
