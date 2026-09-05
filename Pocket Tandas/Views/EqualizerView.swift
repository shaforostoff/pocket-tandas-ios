// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EqualizerView.swift
//  Pocket Tandas
//
//  The parametric EQ panel (a sheet). One section per band, each exposing Gain,
//  Frequency (log-scaled slider) and Bandwidth. Edits apply live to the audio
//  node and persist. A master enable toggle bypasses the whole unit; Reset
//  returns every band to flat defaults.
//
//  The same panel edits the local EQ or — in Remote Control mode — the receiver's,
//  through whichever EqualizerControlling it was handed. While a remote EQ hasn't
//  reported its state yet (`isReady == false`) the controls stay disabled so no
//  edit is sent against invented values.
//
//  It also carries the two disc-restoration filters: a checkbox each to switch
//  them on, and a "…" button each onto the parameters overlay
//  (RestorationSettingsView). Like the bands, they drive either the local chain or
//  the receiver's, through whichever RestorationControlling it was handed.
//

import SwiftUI

struct EqualizerView: View {
    let control: any EqualizerControlling
    var isReady: Bool = true
    /// The restoration filters of the chain this panel is driving — the local
    /// ones, or the receiver's.
    var restoration: (any RestorationControlling)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var editing: RestorationFilter?

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
                    Toggle("Enable EQ", isOn: Binding(
                        get: { control.isEnabled },
                        set: { control.setEnabled($0) }))
                }

                ForEach(control.bands) { band in
                    bandSection(band)
                }

                Section {
                    Button("Reset to Flat", role: .destructive) { control.reset() }
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // Last, and after Reset to Flat, which resets the bands above it
                // and nothing here.
                if let restoration {
                    restorationSection(restoration)
                }
            }
            .disabled(!isReady)
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { filter in
                if let restoration {
                    RestorationSettingsView(filter: filter, restoration: restoration)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Declick and Dehum: a switch each, and a "…" onto the parameters overlay.
    /// The EQ above shapes the sound; these two repair what the disc did to the
    /// recording, which is why they sit in their own section rather than among
    /// the bands.
    @ViewBuilder
    private func restorationSection(_ restoration: any RestorationControlling) -> some View {
        Section("Restoration") {
            filterRow(.declick,
                      isOn: Binding(get: { restoration.declickEnabled },
                                    set: { restoration.setDeclickEnabled($0) }),
                      detail: "Clicks and crackle")
            filterRow(.dehum,
                      isOn: Binding(get: { restoration.dehumEnabled },
                                    set: { restoration.setDehumEnabled($0) }),
                      detail: "Hum, drone and rumble")
        }
    }

    @ViewBuilder
    private func filterRow(_ filter: RestorationFilter, isOn: Binding<Bool>,
                           detail: String) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(filter.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                editing = filter
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            // Borderless, or the row's tap area swallows the button in a Form.
            .buttonStyle(.borderless)
            .accessibilityLabel("\(filter.title) parameters")
        }
    }

    @ViewBuilder
    private func bandSection(_ band: EQBand) -> some View {
        Section(band.name) {
            paramRow(title: "Gain", value: String(format: "%+.1f dB", band.gain)) {
                Slider(value: Binding(get: { band.gain },
                                      set: { control.setGain($0, bandID: band.id) }),
                       in: Equalizer.gainRange)
            }
            paramRow(title: "Frequency", value: frequencyLabel(band.frequency)) {
                // Log-scaled: musical pitch is logarithmic, so a linear Hz slider
                // wastes most of its travel on the top octave.
                Slider(value: Binding(
                    get: { log10(Double(band.frequency)) },
                    set: { control.setFrequency(Float(pow(10.0, $0)), bandID: band.id) }),
                    in: log10(Double(band.frequencyRange.lowerBound))...log10(Double(band.frequencyRange.upperBound)))
            }
            paramRow(title: "Bandwidth", value: String(format: "%.2f oct", band.bandwidth)) {
                Slider(value: Binding(get: { band.bandwidth },
                                      set: { control.setBandwidth($0, bandID: band.id) }),
                       in: Equalizer.bandwidthRange)
            }
        }
        .disabled(!control.isEnabled)
    }

    private func paramRow<Content: View>(title: String, value: String,
                                         @ViewBuilder slider: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            slider()
        }
    }

    private func frequencyLabel(_ hz: Float) -> String {
        hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }
}
