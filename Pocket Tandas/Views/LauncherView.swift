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
import SwiftData

struct LauncherView: View {
    @Environment(AudioSessionController.self) private var audioSession
    @Environment(PlaybackEngine.self) private var engine
    @Environment(PreListenPlayer.self) private var preListen
    @Environment(AudioRouting.self) private var routing
    @State private var activeMode: AppMode?
    @State private var showDJRoutingOptions = false

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

                fadeSection

                Spacer(minLength: 0)

                modeButtons
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
                    Label("DJ fade-out", systemImage: "timer")
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
            Button {
                enter(.explore)
            } label: {
                Label("Explore", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Tap enters DJ mode (auto 4-channel cue on ch 3+4 when ≥4 are
            // available). Press-and-hold to force a routing: 4-channel cue (when
            // detection under-reports) or the 2-channel L/R split for testing.
            Button {
                enter(.dj)
            } label: {
                Label("DJ Mode", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in showDJRoutingOptions = true }
            )
        }
        .confirmationDialog("DJ Output Routing", isPresented: $showDJRoutingOptions,
                            titleVisibility: .visible) {
            Button("Enter DJ Mode") { enter(.dj) }
            Button("4-Channel Cue — Cue ▸ Channels 3+4") { enter(.dj, forcedRouting: .fourChannel) }
            Button("L/R Split Test — Queue ▸ Left, Cue ▸ Right") { enter(.dj, forcedRouting: .stereoSplitTest) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("4-Channel Cue routes the queue to output channels 1+2 and prelistening to 3+4 (needs a multi-channel interface). L/R Split is a 2-channel stand-in: queue to the left, cue to the right (both mono).")
        }
    }

    /// Choose the output routing for the mode being entered, apply it to the
    /// session and both engines (all idle here), then present the screen. A
    /// `forcedRouting` (from the long-press dialog) overrides detection; otherwise
    /// DJ auto-selects a 4-channel cue when the interface offers ≥4 channels, and
    /// Explore always uses the single shared route.
    private func enter(_ appMode: AppMode, forcedRouting: AudioRouting.Mode? = nil) {
        let mode: AudioRouting.Mode
        if let forcedRouting {
            mode = forcedRouting
        } else if appMode == .dj && audioSession.maxOutputChannels >= 4 {
            mode = .fourChannel
        } else {
            mode = .off
        }
        routing.set(mode)
        audioSession.configure(for: mode)
        engine.applyRouting()
        preListen.applyRouting()
        activeMode = appMode
    }
}

#Preview {
    let session = AudioSessionController()
    let queue = PlayQueue()
    let container = try! ModelContainer(for: TrackMetadata.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let metadata = MetadataService(container: container)
    let equalizer = Equalizer()
    let routing = AudioRouting()
    return LauncherView()
        .environment(session)
        .environment(PlaybackEngine(audioSession: session, queue: queue, metadata: metadata, equalizer: equalizer, routing: routing))
        .environment(routing)
        .environment(PreListenPlayer(audioSession: session, routing: routing))
}
