// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  AudioRouting.swift
//  Pocket Tandas
//
//  How the main mix (play queue) and the prelisten "cue" are routed to outputs.
//  Set once when entering a mode from the launcher; read by the two engines when
//  they (re)configure their output graphs, and by the browser to decide whether
//  DJ-mode cueing is offered.
//
//    .off              one shared stereo route. Prelistening is the Explore-mode
//                      audition that only plays while the queue is idle.
//    .fourChannel      true DJ cue: main mix → output channels 1+2, cue → 3+4
//                      (both stereo). Needs an interface exposing ≥4 channels.
//    .stereoSplitTest  a 2-channel stand-in for cueing so it can be exercised
//                      without a 4-channel interface: main mix downmixed to mono
//                      on the LEFT, cue downmixed to mono on the RIGHT.
//
//  In the two cue modes the queue and cue play *concurrently* on separate outputs
//  and are fully independent (the queue's Stop/fade never touches the cue).
//

import Foundation
import Observation

@Observable
final class AudioRouting {
    enum Mode: Equatable {
        case off
        case fourChannel
        case stereoSplitTest
    }

    private(set) var mode: Mode = .off

    /// True when a separate cue output exists — i.e. DJ-mode prelistening is
    /// available and plays alongside the queue rather than being idle-gated.
    var cueEnabled: Bool { mode != .off }

    func set(_ mode: Mode) { self.mode = mode }
}
