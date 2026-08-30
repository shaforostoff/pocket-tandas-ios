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

import SwiftUI

struct EqualizerView: View {
    @Environment(Equalizer.self) private var equalizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable EQ", isOn: Binding(
                        get: { equalizer.isEnabled },
                        set: { equalizer.setEnabled($0) }))
                }

                ForEach(equalizer.bands) { band in
                    bandSection(band)
                }

                Section {
                    Button("Reset to Flat", role: .destructive) { equalizer.reset() }
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
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
    private func bandSection(_ band: Equalizer.Band) -> some View {
        Section(band.name) {
            paramRow(title: "Gain", value: String(format: "%+.1f dB", band.gain)) {
                Slider(value: Binding(get: { band.gain },
                                      set: { equalizer.setGain($0, bandID: band.id) }),
                       in: Equalizer.gainRange)
            }
            paramRow(title: "Frequency", value: frequencyLabel(band.frequency)) {
                // Log-scaled: musical pitch is logarithmic, so a linear Hz slider
                // wastes most of its travel on the top octave.
                Slider(value: Binding(
                    get: { log10(Double(band.frequency)) },
                    set: { equalizer.setFrequency(Float(pow(10.0, $0)), bandID: band.id) }),
                    in: log10(Double(band.frequencyRange.lowerBound))...log10(Double(band.frequencyRange.upperBound)))
            }
            paramRow(title: "Bandwidth", value: String(format: "%.2f oct", band.bandwidth)) {
                Slider(value: Binding(get: { band.bandwidth },
                                      set: { equalizer.setBandwidth($0, bandID: band.id) }),
                       in: Equalizer.bandwidthRange)
            }
        }
        .disabled(!equalizer.isEnabled)
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
