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
//  rest. Encoded as JSON (debuggable, version-tolerant; payloads are small).
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

    // MARK: Receiver → Sender (state)
    case snapshot(RemoteSnapshot)          // on structural change
    case progress(RemoteProgress)          // on timer
    case addTrackResult(resolved: Int, failed: Int)
}

extension RemoteMessage {
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> RemoteMessage? {
        try? JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}
