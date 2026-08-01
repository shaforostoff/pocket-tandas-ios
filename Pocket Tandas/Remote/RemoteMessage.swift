// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteMessage.swift
//  Pocket Tandas
//
//  The single message type exchanged over the peer link, carrying both
//  directions. Each side handles only the cases meant for it and ignores the
//  rest. Encoded as JSON (debuggable, version-tolerant).
//
//  Frames carry a one-byte prefix so the JSON can be zlib-compressed — queue
//  snapshots are long, repetitive text and typically shrink several-fold, which
//  matters on the Bluetooth-only path where there is no Wi-Fi to fall back on.
//  Compression is used only when it actually helps; a frame that starts with
//  neither marker is read as bare JSON, so a peer running an older build is still
//  understood.
//

import Foundation

enum RemoteMessage: Codable {
    // MARK: Sender → Receiver (commands)
    case requestPlay(itemID: UUID)
    case stopWithFade
    case resumeFromFade
    case setAnchor(itemID: UUID?)          // nil clears the anchor
    case move(itemIDs: [UUID], toOffset: Int)
    case removeItems(itemIDs: [UUID])
    case addTracks([TrackAddRequest])
    case requestSnapshot                   // resync on (re)connect
    // Audio chain: the sender edits the receiver's EQ / master volume. Band edits
    // carry all three parameters so a dropped intermediate value can't leave the
    // two sides disagreeing about the band.
    case setEQEnabled(Bool)
    case setEQBand(id: Int, gain: Float, frequency: Float, bandwidth: Float)
    case resetEQ
    case setVolume(Float)
    case requestAudioSettings              // resync on (re)connect

    // MARK: Receiver → Sender (state)
    case snapshot(RemoteSnapshot)          // on structural change
    case playbackState(RemotePlaybackUpdate)  // on engine state change, queue unchanged
    case progress(RemoteProgress)          // on timer
    case addTrackResult(resolved: Int, failed: Int)
    case audioSettings(RemoteAudioSettings)   // EQ + volume, on change

    // MARK: Either direction
    /// "I am disconnecting on purpose" — stops the sender's auto-reconnect from
    /// immediately undoing a Disconnect tapped at either end.
    case goodbye
}

extension RemoteMessage {
    /// Frame markers. Values are outside the range of any JSON opening byte, so a
    /// legacy uncompressed frame can never be mistaken for a marked one.
    private enum Frame {
        static let raw: UInt8 = 0x00
        static let zlib: UInt8 = 0x01
    }

    func encoded() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        if let deflated = try? (json as NSData).compressed(using: .zlib) as Data,
           deflated.count + 1 < json.count {
            return [Frame.zlib] + deflated
        }
        return [Frame.raw] + json
    }

    static func decode(_ data: Data) -> RemoteMessage? {
        guard let marker = data.first else { return nil }
        let body = data.dropFirst()
        switch marker {
        case Frame.zlib:
            guard let inflated = try? (Data(body) as NSData).decompressed(using: .zlib) as Data else { return nil }
            return try? JSONDecoder().decode(RemoteMessage.self, from: inflated)
        case Frame.raw:
            return try? JSONDecoder().decode(RemoteMessage.self, from: Data(body))
        default:
            // Unmarked: a peer on an older build sending bare JSON.
            return try? JSONDecoder().decode(RemoteMessage.self, from: data)
        }
    }
}
