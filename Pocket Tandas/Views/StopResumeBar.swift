// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  StopResumeBar.swift
//  Pocket Tandas
//
//  The middle control between browser and queue.
//
//  DJ mode (and Remote Receive): Stop (a configurable fade-out) while playing,
//  turning into Resume while the fade is in progress (Resume cancels the
//  scheduled stop). The row also carries the EQ button.
//
//  Remote Send: the same Stop ⇄ Resume control, but bound to the RemoteQueue —
//  so it drives the receiver's fade and reflects the receiver's broadcast state
//  (Resume shows while the receiver is fading). No local-queue buttons; instead the
//  row carries Volume and EQ, both wired to the RECEIVER's audio chain.
//
//  Explore mode: Pause / Play instead — Pause holds the current track and Play
//  resumes it from where it left off. The row also carries Clear and Save for the
//  play queue.
//
//  The control is abstracted behind PlaybackControlling so the same view drives
//  either the local PlaybackEngine or a RemoteQueue.
//

import SwiftUI

struct StopResumeBar: View {
    let mode: AppMode
    let control: any PlaybackControlling
    /// Remote Send only: the receiver's EQ + master volume over the peer link.
    var remoteAudio: RemoteAudioControl? = nil

    @Environment(Equalizer.self) private var equalizer

    var body: some View {
        HStack(spacing: 8) {
            // Save/Clear act on the local queue — only in plain Explore (Remote
            // Send hides its local queue and leaves it untouched).
            if mode == .explore {
                SavePlaylistButton()
                ClearQueueButton()
            }
            // EQ edits whatever device is playing: the local chain in plain DJ /
            // Remote Receive, the receiver's chain from the Remote Control screen.
            // Volume is remote-only — locally the hardware keys already do it, but
            // they can't reach the phone wired to the speakers.
            if let remoteAudio, mode.isRemoteSend {
                VolumeButton(control: remoteAudio, isReady: remoteAudio.hasSettings)
                EQButton(control: remoteAudio, isReady: remoteAudio.hasSettings)
            } else if mode.isDJLike {
                EQButton(control: equalizer)
            }
            playbackControl
        }
        .controlSize(.large)
        // Keep each label on one line: "Pause" is wider than the old "Stop" and
        // overflowed the equal-thirds Explore row. Trim the margins for room and
        // allow a slight shrink as a last resort so nothing wraps/truncates.
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    /// Explore is the only Pause/Play mode; DJ, Remote Receive and Remote Send all
    /// use the Stop ⇄ Resume fade control (Remote Send drives the receiver).
    @ViewBuilder
    private var playbackControl: some View {
        if mode == .explore {
            exploreControl
        } else {
            djControl
        }
    }

    /// DJ: Stop (fade-out) ⇄ Resume (cancel the in-progress fade).
    @ViewBuilder
    private var djControl: some View {
        if control.isFadingOut {
            Button {
                control.resumeFromFade()
            } label: {
                Label("Resume", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else {
            Button(role: .destructive) {
                control.stopWithFade()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!control.isPlaying)
        }
    }

    /// Explore: Pause ⇄ Play (continue from the paused position).
    @ViewBuilder
    private var exploreControl: some View {
        if control.isPaused {
            Button {
                control.resume()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else {
            Button {
                control.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!control.isPlaying)
        }
    }
}
