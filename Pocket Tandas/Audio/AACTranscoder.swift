// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AACTranscoder.swift
//  Pocket Tandas
//
//  Re-encodes a track as AAC in an .m4a, tags included — the compressed copy
//  Remote Send offers when a track the receiver lacks is heavier than 128 kbps.
//  Stereo goes at 96 kbps; a mono recording at 64 kbps in one channel. Over
//  Bluetooth a FLAC is seven or eight times the transfer of the stereo copy, and
//  for a dance floor the difference is not audible.
//
//  Most golden-age tango is mono, but it usually comes as a stereo file with the
//  same signal in both channels — which costs a stereo encoder half its bits for
//  nothing. So a two-channel track is first read through once to see whether its
//  channels differ (see `isDualMono`), and if they don't it is encoded as one.
//  The fold to one channel is done here, as (L + R) / 2: asked for one channel,
//  the reader sums the two at −3 dB each, which leaves identical channels 3 dB
//  louder and can clip them.
//
//  Decode → encode runs through AVAssetReader / AVAssetWriter rather than an
//  export session: the Apple M4A export preset picks its own bit rate. The file is
//  written whole before it is sent, because an .m4a's index is written last and a
//  half-written one is unplayable; at encode speed that is a few seconds against
//  the minutes the Bluetooth transfer itself takes.
//
//  The AAC encoder takes 48 kHz at most, so anything above (or an odd rate below)
//  is resampled by the reader: to 44.1 kHz, or 48 kHz for the 48k family. More than
//  two channels are folded to stereo.
//

import Foundation
import AVFoundation

enum AACTranscoder {
    /// A track is worth a compressed copy above this.
    static let compressAbove = 128_000
    static let stereoBitRate = 96_000
    static let monoBitRate = 64_000

    static func bitRate(channels: Int) -> Int {
        channels == 1 ? monoBitRate : stereoBitRate
    }

    enum TranscodeError: Error {
        case noAudioTrack
        case unsupported
        case failed(Error?)
        case cancelled
    }

    private static let queue = DispatchQueue(label: "AACTranscoder", qos: .utility)

    /// Formats the file browser lists but AVFoundation can't decode, so there is
    /// nothing to re-encode from.
    private static let undecodable: Set<String> = ["ogg", "opus"]

    static func canDecode(_ url: URL) -> Bool {
        !undecodable.contains(url.pathExtension.lowercased())
    }

    /// Write `source` to `destination` as AAC. Overwrites; on any failure or
    /// cancellation nothing is left at `destination`.
    static func transcode(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.noAudioTrack
        }
        let format = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let tags = await M4ATagMapper.items(for: asset)
        let sampleRate = targetRate(for: format?.mSampleRate ?? 44_100)
        let sourceChannels = max(Int(format?.mChannelsPerFrame ?? 2), 1)

        let flag = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        // More than two channels is a real multichannel mix: folded
                        // to stereo by the reader, never checked for mono.
                        let readChannels = min(sourceChannels, 2)
                        let fold = sourceChannels == 2
                            ? try isDualMono(track: track, of: asset, sampleRate: sampleRate, cancelled: flag)
                            : false
                        ptLog("[AACTranscoder] \(source.lastPathComponent): \(sourceChannels) ch"
                              + (fold ? ", same in both — encoding as mono" : ""))
                        try encode(track: track, of: asset, to: destination, sampleRate: sampleRate,
                                   readChannels: readChannels, foldToMono: fold, tags: tags, cancelled: flag)
                        done.resume()
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        done.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private static func targetRate(for source: Double) -> Double {
        if source == 44_100 || source == 48_000 { return source }
        return source.truncatingRemainder(dividingBy: 48_000) == 0 ? 48_000 : 44_100
    }

    /// Whether a two-channel track carries one signal twice, judged on energy:
    /// the difference between the channels at least 60 dB below their sum over
    /// the whole track. Dither or last-bit rounding passes; any real stereo image,
    /// even a narrow one, fails — usually within seconds, where the read stops.
    /// Blocking: runs on `queue`.
    private static func isDualMono(track: AVAssetTrack, of asset: AVURLAsset, sampleRate: Double,
                                   cancelled: CancelFlag) throws -> Bool {
        let (reader, output) = try PCMAssetReader.make(track: track, of: asset, sampleRate: sampleRate,
                                                       channels: 2, layout: .interleaved)
        guard reader.startReading() else { throw TranscodeError.failed(reader.error) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var sum = 0.0, difference = 0.0
        var frames = 0
        // Five seconds in, a difference within 40 dB of the sum is stereo for
        // sure; before that a quiet intro could make tape hiss look like one.
        let settled = Int(sampleRate * 5)
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.isSet { throw TranscodeError.cancelled }
            PCMAssetReader.withAudioBuffers(sample, maximumBuffers: 1) { list, _ in
                guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let count = PCMAssetReader.frameCount(of: list[0], channels: 2)
                var s: Float = 0, d: Float = 0
                for i in 0..<count {
                    let left = data[2 * i], right = data[2 * i + 1]
                    s += (left + right) * (left + right)
                    d += (left - right) * (left - right)
                }
                sum += Double(s)
                difference += Double(d)
                frames += count
            }
            if frames >= settled && difference > sum * 1e-4 { return false }
        }
        guard reader.status != .failed else { throw TranscodeError.failed(reader.error) }
        return difference <= sum * 1e-6
    }

    /// Blocking: runs on `queue`.
    private static func encode(track: AVAssetTrack, of asset: AVURLAsset, to destination: URL,
                               sampleRate: Double, readChannels: Int, foldToMono: Bool,
                               tags: [AVMetadataItem], cancelled: CancelFlag) throws {
        try? FileManager.default.removeItem(at: destination)
        let (reader, output) = try PCMAssetReader.make(track: track, of: asset, sampleRate: sampleRate,
                                                       channels: readChannels, layout: .interleaved)
        let channels = foldToMono ? 1 : readChannels
        let monoFormat = foldToMono ? try monoFormat(sampleRate: sampleRate) : nil
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: destination, fileType: .m4a) }
        catch { throw TranscodeError.failed(error) }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate(channels: channels),
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        // AVAssetWriterInput raises an Objective-C exception on settings it can't
        // take, which Swift cannot catch — so ask first.
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw TranscodeError.unsupported
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TranscodeError.unsupported }
        writer.add(input)
        writer.metadata = tags

        guard reader.startReading() else { throw TranscodeError.failed(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.failed(writer.error)
        }

        // The pump runs on its own queue; this thread waits for it.
        let pumped = DispatchSemaphore(value: 0)
        var failure: TranscodeError?
        var started = false
        var finished = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "AACTranscoder.pump")) {
            while !finished && input.isReadyForMoreMediaData {
                if cancelled.isSet {
                    failure = .cancelled
                } else if let read = output.copyNextSampleBuffer() {
                    guard let sample = monoFormat.map({ averaged(read, as: $0) }) ?? read else {
                        failure = .failed(nil)
                        finished = true
                        input.markAsFinished()
                        pumped.signal()
                        return
                    }
                    if !started {
                        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                        started = true
                    }
                    if input.append(sample) { continue }
                    failure = .failed(writer.error)
                } else if reader.status == .failed {
                    failure = .failed(reader.error)
                }
                finished = true
                input.markAsFinished()
                pumped.signal()
            }
        }
        pumped.wait()

        if let failure {
            reader.cancelReading()
            writer.cancelWriting()
            throw failure
        }
        guard started else {
            writer.cancelWriting()
            throw TranscodeError.noAudioTrack
        }
        let written = DispatchSemaphore(value: 0)
        writer.finishWriting { written.signal() }
        written.wait()
        guard writer.status == .completed else { throw TranscodeError.failed(writer.error) }
    }
}

// MARK: - Folding to mono

extension AACTranscoder {
    /// Float32 PCM, one channel — what `averaged` hands the encoder.
    fileprivate static func monoFormat(sampleRate: Double) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                                    layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &format)
        guard status == noErr, let format else { throw TranscodeError.unsupported }
        return format
    }

    /// One block of interleaved stereo as (L + R) / 2, stamped with the block's
    /// own time. Nil if it can't be read or built.
    fileprivate static func averaged(_ sample: CMSampleBuffer, as format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let folded = PCMAssetReader.withAudioBuffers(sample, maximumBuffers: 1) { list, _ -> CMSampleBuffer? in
            guard let source = list[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let frames = PCMAssetReader.frameCount(of: list[0], channels: 2)
            let bytes = frames * MemoryLayout<Float>.size
            var block: CMBlockBuffer?
            guard frames > 0,
                  CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                     blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag,
                                                     blockBufferOut: &block) == noErr,
                  let block else { return nil }
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
                  let pointer else { return nil }
            pointer.withMemoryRebound(to: Float.self, capacity: frames) { out in
                for i in 0..<frames { out[i] = (source[2 * i] + source[2 * i + 1]) * 0.5 }
            }
            var result: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: frames, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                    packetDescriptions: nil, sampleBufferOut: &result) == noErr else { return nil }
            return result
        }
        return folded ?? nil
    }
}

/// Set from a cancellation handler, read from the pump.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
