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

import SwiftUI

struct EqualizerView: View {
    let control: any EqualizerControlling
    var isReady: Bool = true

    @Environment(\.dismiss) private var dismiss

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
            }
            .disabled(!isReady)
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
