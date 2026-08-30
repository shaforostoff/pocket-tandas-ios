// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  VolumeButton.swift
//  Pocket Tandas
//
//  Control-bar button, sitting to the left of EQ in Remote Control mode: the
//  sender's hardware volume keys can't touch the phone wired to the speakers, so
//  the master output level of the RECEIVER gets its own control here. Tinted while
//  the level is below full so an attenuated rig is visible at a glance.
//

import SwiftUI

struct VolumeButton: View {
    let control: any VolumeControlling
    /// Disables the panel while a remote level hasn't been reported yet.
    var isReady: Bool = true

    @State private var showingPanel = false

    var body: some View {
        Button {
            showingPanel = true
        } label: {
            Label("Volume", systemImage: icon)
        }
        .buttonStyle(.bordered)
        .tint(control.isAttenuated ? Color.accentColor : nil)
        .sheet(isPresented: $showingPanel) {
            VolumeView(control: control, isReady: isReady)
        }
    }

    private var icon: String {
        switch control.masterVolume {
        case ..<0.001: return "speaker.slash"
        case ..<0.34: return "speaker.wave.1"
        case ..<0.67: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

/// The master-volume panel (a sheet): one slider, a percentage read-out, and Mute /
/// Full shortcuts. Edits apply live.
struct VolumeView: View {
    let control: any VolumeControlling
    var isReady: Bool = true

    @Environment(\.dismiss) private var dismiss

    /// Fader position plus the attenuation it actually applies — the percentage
    /// alone hides the taper (see VolumeTaper), and a DJ thinks in dB anyway.
    private var levelLabel: String {
        let percent = Int((control.masterVolume * 100).rounded())
        guard let dB = VolumeTaper.decibels(for: control.masterVolume) else { return "Muted" }
        return String(format: "%d %%  ·  %.1f dB", percent, dB)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isReady {
                    Section {
                        Label("Waiting for the receiver…", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Master Volume")
                            Spacer()
                            Text(levelLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(control.masterVolume) },
                                              set: { control.setMasterVolume(Float($0)) }),
                               in: 0...1) {
                            Text("Master volume")
                        } minimumValueLabel: {
                            Image(systemName: "speaker.fill")
                        } maximumValueLabel: {
                            Image(systemName: "speaker.wave.3.fill")
                        }
                    }
                } footer: {
                    Text("Sets the app's output level on the device that is playing, "
                         + "underneath that device's own volume buttons. "
                         + "Fade-outs ramp from this level.")
                }

                Section {
                    HStack {
                        Button("Mute") { control.setMasterVolume(0) }
                        Spacer()
                        Button("Full") { control.setMasterVolume(1) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(!isReady)
            .navigationTitle("Volume")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
