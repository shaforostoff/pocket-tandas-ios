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

            // Tap enters DJ mode (cueing on channels 3+4 when ≥4 are available).
            // Press-and-hold offers the 2-channel L/R split for testing cueing
            // without a 4-channel interface.
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
            Button("L/R Split Test — Queue ▸ Left, Cue ▸ Right") { enter(.dj, splitTest: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("L/R Split routes the play queue to the left channel and prelistening to the right (both downmixed to mono) — for testing cueing without a 4-channel interface.")
        }
    }

    /// Choose the output routing for the mode being entered, apply it to the
    /// session and both engines (all idle here), then present the screen.
    /// Explore always uses the single shared route; DJ uses a true 4-channel cue
    /// when the interface offers ≥4 channels, the L/R split when forced, else none.
    private func enter(_ appMode: AppMode, splitTest: Bool = false) {
        let mode: AudioRouting.Mode
        if splitTest {
            mode = .stereoSplitTest
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
