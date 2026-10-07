// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AACTranscoder.swift
//  Pocket Tandas
//
//  Re-encodes a track as 128 kbps AAC in an .m4a, tags included — the compressed
//  copy Remote Send offers when a track the receiver lacks is heavier than that.
//  Over Bluetooth a FLAC is five or six times the transfer of the same track at
//  128 kbps, and for a dance floor the difference is not audible.
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
    static let bitRate = 128_000

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
        let channels = min(max(Int(format?.mChannelsPerFrame ?? 2), 1), 2)

        let flag = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try encode(track: track, of: asset, to: destination, sampleRate: sampleRate,
                                   channels: channels, tags: tags, cancelled: flag)
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

    /// Blocking: runs on `queue`.
    private static func encode(track: AVAssetTrack, of asset: AVURLAsset, to destination: URL,
                               sampleRate: Double, channels: Int, tags: [AVMetadataItem],
                               cancelled: CancelFlag) throws {
        try? FileManager.default.removeItem(at: destination)
        let (reader, output) = try PCMAssetReader.make(track: track, of: asset, sampleRate: sampleRate,
                                                       channels: channels, layout: .interleaved)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: destination, fileType: .m4a) }
        catch { throw TranscodeError.failed(error) }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
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
                } else if let sample = output.copyNextSampleBuffer() {
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
