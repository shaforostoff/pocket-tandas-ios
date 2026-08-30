// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PlaybackControlling.swift
//  Pocket Tandas
//
//  Lets StopResumeBar drive either the local PlaybackEngine or a RemoteQueue
//  (which forwards the same intents to the receiver). The DJ-style Stop ⇄ Resume
//  fade control becomes source-agnostic: in Remote Send mode the bar binds to the
//  RemoteQueue, whose `isFadingOut` reflects the receiver's broadcast state.
//

import Foundation

protocol PlaybackControlling {
    var isPlaying: Bool { get }
    var isFadingOut: Bool { get }
    var isPaused: Bool { get }
    func stopWithFade()
    func resumeFromFade()
    func pause()
    func resume()
}

extension PlaybackEngine: PlaybackControlling {
    var isPlaying: Bool { state.isPlaying }
    var isFadingOut: Bool { state.isFadingOut }
    var isPaused: Bool { state.isPaused }
    // stopWithFade(), resumeFromFade(), pause(), resume() already exist.
}
