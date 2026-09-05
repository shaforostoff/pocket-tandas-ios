// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  DehumTrackScout.swift
//  Pocket Tandas
//
//  Background analysis of the track that is playing, so the hum is gone from
//  the first bar instead of from the first minute.
//
//  Dehum's detector will not commit to a line until it has several seconds of
//  steady evidence, and on the transfers this exists for that is not a few
//  seconds but the better part of a minute (see DSP/dehum_core.h): a line the
//  prominence route can see is confirmed about 9 s in, one that only the
//  coherence route can reach at about 43 s, because that ratio accumulates over
//  `kCohWindowSec`. All of it is time the record plays with the hum still in it.
//
//  A file player does not have to spend it. The whole track is readable — a file
//  on disk or an `ipod-library://` asset — so it can be decoded far faster than
//  it plays, on a worker queue, while the opening bars are still going out. What
//  that finds goes to `PTDehumProcessor.adoptLines`, which starts those lines
//  confirmed and leaves the live detector running: it still tracks them, still
//  drops them if the evidence is not really there, and can still find others.
//
//  Deliberately per track — each record carries its own hum, so a scan is
//  started fresh for every one and publishes exactly once. This is the same job
//  the foobar2000 component's `dehum_scout` and the VirtualDJ port's
//  `DehumScout` do, in the shape this app can do it.
//

import Foundation
import AVFoundation

final class DehumTrackScout {

    /// How much of the track is read. Sixty seconds, the figure both other ports
    /// use and for the same reason: the coherence route accumulates its ratio
    /// over `dehum::kCohWindowSec`, so the lines that most need scouting are
    /// exactly the ones that need most of this window. A shorter track is read
    /// to its end.
    static let secondsToRead: TimeInterval = 60

    /// Below this the prominence route has barely had time to confirm anything
    /// and the coherence route none at all, so a result is not yet worth acting
    /// on — and it is also how soon the scan may stop early once it does have
    /// one. A line the prominence route can see turns up in the first ten
    /// seconds and there is nothing to be gained by reading the other fifty.
    static let minimumSeconds: TimeInterval = 10

    /// Analysed mono at a fixed rate, whatever the track's own is. Hum sits at
    /// the same frequency in Hz however you look at it, so the result transfers
    /// straight to a live unit running at the device rate — and hum is common
    /// mode, so one summed channel finds it for a fraction of the work.
    static let analysisSampleRate: Double = 44_100

    /// The scan's outcome, for the parameters overlay.
    enum State: Equatable {
        case idle
        case scanning
        /// Finished. Empty means the track was read and nothing was found.
        case finished([DehumLine])
        /// Not attempted — no readable asset, or the frequency is pinned by hand.
        case skipped

        /// The payload-free form the restoration panel reads — and the only form
        /// that crosses the peer link, since the lines themselves reach the panel
        /// through `RestorationControlling.detectedLines`.
        var phase: RestorationScoutPhase {
            switch self {
            case .idle: return .idle
            case .scanning: return .scanning
            case .finished(let lines): return lines.isEmpty ? .foundNothing : .found
            case .skipped: return .skipped
            }
        }
    }

    /// Latest state, on the main thread.
    private(set) var state: State = .idle

    /// Called on the main thread when a scan finishes with something to adopt.
    var onLines: (([DehumLine]) -> Void)?
    /// Called on the main thread whenever `state` changes.
    var onStateChange: (() -> Void)?

    private let queue = DispatchQueue(label: "tandas.dehumscout", qos: .utility)

    /// Bumped on the main thread whenever a scan is started or cancelled, so a
    /// superseded worker's result is dropped rather than published.
    private var token = 0

    /// Shared with the worker so a cancel reaches it between sample buffers, and
    /// so the reader itself can be stopped mid-read.
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

    // MARK: - Driving

    /// Start scanning `url`. Any scan already running is cancelled first — a new
    /// record means the previous one's answer is no longer wanted.
    func scan(url: URL?, params: PTDehumParams) {
        cancel()

        guard let url, params.frequency <= 0 else {
            // A frequency pinned by hand outranks anything found by searching,
            // and `adopt` would refuse the result anyway.
            setState(.skipped)
            return
        }

        token += 1
        let token = self.token
        let job = Job()
        self.job = job
        setState(.scanning)

        queue.async { [weak self] in
            let lines = Self.run(url: url, params: params, job: job)
            DispatchQueue.main.async {
                guard let self, token == self.token else { return }
                self.job = nil
                self.setState(.finished(lines))
                if !lines.isEmpty { self.onLines?(lines) }
            }
        }
    }

    /// Stop any scan in flight and forget its result.
    func cancel() {
        token += 1
        job?.cancel()
        job = nil
        setState(.idle)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?()
    }

    // MARK: - The worker

    /// Reads the opening of `url` and returns what dehum settles on. Runs on the
    /// scout queue; returns an empty array for anything unreadable, unsupported
    /// or cancelled — scouting is an optimisation, and without it the live
    /// detector still gets there, just later.
    private static func run(url: URL, params: PTDehumParams, job: Job) -> [DehumLine] {
        let rate = analysisSampleRate
        let asset = AVURLAsset(url: url)

        guard let track = firstAudioTrack(of: asset), !job.isCancelled else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            // Mono: the reader does the downmix, which is what the detector wants.
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else { return [] }
        reader.add(output)
        guard job.adopt(reader), reader.startReading() else { return [] }

        let scout = PTDehumScout(sampleRate: rate, params: params)
        let wanted = Int(secondsToRead * rate)
        let least = Int(minimumSeconds * rate)
        var read = 0

        while reader.status == .reading, read < wanted, !job.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                read += feed(sample, to: scout, limit: wanted - read)
            }
            // Enough of the record has been read to trust what came out of it,
            // and there is something to hand over. Reading the rest would cost
            // I/O and a core for nothing.
            if read >= least, scout.lineCount > 0 { break }
        }

        let completed = reader.status == .reading || reader.status == .completed
        reader.cancelReading()

        guard completed, !job.isCancelled, read >= least else { return [] }

        var wire = [PTDehumLine](repeating: PTDehumLine(), count: Int(PTDehumMaxLines))
        let count = wire.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return scout.report(base, max: buffer.count)
        }
        return (0..<count).map { DehumLine(id: $0, wire: wire[$0]) }
    }

    /// Hand one decoded sample buffer to the scout, at most `limit` frames of it.
    /// Returns how many frames were fed.
    private static func feed(_ sample: CMSampleBuffer, to scout: PTDehumScout, limit: Int) -> Int {
        let frames = min(CMSampleBufferGetNumSamples(sample), limit)
        guard frames > 0 else { return 0 }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return 0 }

        return withExtendedLifetime(blockBuffer) {
            let available = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(frames, available)
            guard count > 0 else { return 0 }
            scout.feedMono(data.assumingMemoryBound(to: Float.self), frames: count)
            return count
        }
    }

    /// `AVAsset.loadTracks` is async; this runs on a private dispatch queue and
    /// never on a Swift Concurrency executor, so bridging it back with a
    /// semaphore cannot starve the cooperative pool — the same trade
    /// MediaTrackDecoder makes for the same reason.
    private static func firstAudioTrack(of asset: AVURLAsset) -> AVAssetTrack? {
        final class Box: @unchecked Sendable { var tracks: [AVAssetTrack] = [] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            semaphore.signal()
        }
        semaphore.wait()
        return box.tracks.first
    }
}
