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

    /// The two opt-in ways to keep the app running while it sits idle — see
    /// StayAwake.swift. Both off by default, both time-limited.
    @AppStorage(StayAwakeSettings.screenAwakeKey) private var screenStaysAwake = false
    @AppStorage(StayAwakeSettings.silentKeepAliveKey) private var silentKeepAlive = false

    var body: some View {
        NavigationStack {
            // Scrolls only when the content outgrows the screen (small phones);
            // the min-height keeps the Spacers centring it on roomier ones.
            GeometryReader { proxy in
                ScrollView {
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

                        stayAwakeSection

                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(minHeight: proxy.size.height)
                }
            }
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

    /// Keeping the app running while it idles. Both switches are off by default:
    /// without one, iOS suspends the app once the screen locks, and a Remote
    /// Controllable phone drops off the air until it is unlocked again.
    private var stayAwakeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $screenStaysAwake) {
                    Label("Screen Stays Awake", systemImage: "sun.max")
                        .font(.subheadline)
                }
                Toggle(isOn: $silentKeepAlive) {
                    Label("Silent Keep-Alive Audio", systemImage: "waveform")
                        .font(.subheadline)
                }
                Text("Stop iOS suspending the app while it idles, so a Remote Controllable "
                     + "phone stays reachable — the keep-alive also works with the screen "
                     + "off. Both release after \(minutes) minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var minutes: Int { Int(StayAwakeSettings.window / 60) }

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
                    Label("Remote Controllable", systemImage: "antenna.radiowaves.left.and.right")
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
