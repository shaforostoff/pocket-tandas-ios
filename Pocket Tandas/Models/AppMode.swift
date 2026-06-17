// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AppMode.swift
//  Pocket Tandas
//
//  The shared main screen carries this flag. Both launcher buttons currently
//  lead to identical behaviour; the seam is here for future divergence.
//

import Foundation

enum AppMode: String, Identifiable, Hashable, CaseIterable {
    case explore
    case dj
    /// Extends Explore: drives a remote receiver (hides the local queue, shows a
    /// mirror of the receiver's queue, sends control commands + track requests).
    case remoteSend
    /// Extends DJ: exposes its play queue and playback state to a remote sender
    /// and applies the sender's commands locally.
    case remoteReceive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .dj: return "DJ Mode"
        case .remoteSend: return "Remote Send"
        case .remoteReceive: return "Remote Receive"
        }
    }

    /// Behaves like DJ mode for the local transport controls (Stop/Resume fade,
    /// EQ): plain DJ and the remote receiver (the phone wired to the speakers).
    var isDJLike: Bool { self == .dj || self == .remoteReceive }

    /// Behaves like Explore for the browser (tap-to-audition / prelistening):
    /// plain Explore and the remote sender (the DJ monitors on headphones).
    var isExploreLike: Bool { self == .explore || self == .remoteSend }

    var isRemoteSend: Bool { self == .remoteSend }
    var isRemoteReceive: Bool { self == .remoteReceive }
    var isRemote: Bool { isRemoteSend || isRemoteReceive }
}
