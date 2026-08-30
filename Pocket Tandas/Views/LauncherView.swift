// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  LauncherView.swift
//  Pocket Tandas
//
//  Initial screen: output settings + Explore / DJ Mode entry points.
//  Both buttons open the same MainScreenView, differing only by mode flag.
//

import SwiftUI

struct LauncherView: View {
    @Environment(AudioSessionController.self) private var audioSession
    @State private var activeMode: AppMode?

    /// DJ-mode Stop fade-out length, shared with the engine via UserDefaults.
    @AppStorage(PlaybackEngine.fadeOutDurationKey)
    private var fadeOutSeconds: Double = PlaybackEngine.defaultFadeOutDuration

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("Pocket Tandas")
                        .font(.largeTitle.bold())
                    Text("Live DJ play queue")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                outputSection

                modeButtons

                fadeSection

                Spacer(minLength: 0)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(item: $activeMode) { mode in
            MainScreenView(mode: mode)
        }
    }

    private var outputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Output", systemImage: "hifispeaker")
                        .font(.headline)
                    Spacer()
                    RoutePickerView()
                        .frame(width: 40, height: 40)
                }
                CurrentRouteView(description: audioSession.currentRouteDescription)
            }
        }
    }

    private var fadeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Fade-out for DJ Mode", systemImage: "timer")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(fadeOutSeconds.rounded())) s")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $fadeOutSeconds,
                       in: PlaybackEngine.fadeOutDurationRange,
                       step: 1) {
                    Text("Fade-out duration")
                } minimumValueLabel: {
                    Text("1s")
                } maximumValueLabel: {
                    Text("10s")
                }
            }
        }
    }

    private var modeButtons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    activeMode = .explore
                } label: {
                    Label("Explore", systemImage: "folder")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    activeMode = .remoteSend
                } label: {
                    Label("Remote Control", systemImage: "dot.radiowaves.right")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 14) {
                Button {
                    activeMode = .dj
                } label: {
                    Label("DJ Mode", systemImage: "slider.horizontal.3")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    activeMode = .remoteReceive
                } label: {
                    Label("DJ Mode + Remote", systemImage: "antenna.radiowaves.left.and.right")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
}

#Preview {
    LauncherView()
        .environment(AudioSessionController())
}
