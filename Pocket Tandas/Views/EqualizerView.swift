// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EqualizerView.swift
//  Pocket Tandas
//
//  The parametric EQ panel (a sheet): the response curve pinned at the top, and
//  below it one section per band. The curve stays put while a slider is dragged —
//  the point of the "EQ 4 TJ" technique is the shape of the whole curve, not any
//  one band's number, and a section that scrolled away with the sliders would
//  never be looked at.
//
//  Each band shows only the controls its kind has: the two rails a corner
//  frequency and a switch, the shelves frequency and gain, the two peaking bands
//  frequency, gain and Q. Tapping a marker on the curve selects a band and scrolls
//  to it. Edits apply live to the audio node and persist. A master enable toggle
//  bypasses the whole unit; the presets at the bottom load the article's three
//  starting points.
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
    /// The band whose marker was last tapped on the curve, if any.
    @State private var selected: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EQCurveView(bands: control.bands, sampleRate: control.sampleRate,
                            selection: $selected, isEQEnabled: control.isEnabled && isReady)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                ScrollViewReader { proxy in
                    form
                        .onChange(of: selected) { _, band in
                            guard let band else { return }
                            withAnimation { proxy.scrollTo(band, anchor: .top) }
                        }
                }
            }
            .disabled(!isReady)
            .navigationTitle("Equalizer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        // Six bands and a plot don't fit a medium detent, and half a curve is
        // worse than none.
        .presentationDetents([.large])
    }

    private var form: some View {
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

            presetSection

            // Last, and after the presets, which reload the bands above them
            // and nothing here.
            if let restoration {
                restorationSection(restoration)
            }
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            Menu {
                ForEach(EQPreset.allCases) { preset in
                    Button {
                        selected = nil
                        control.apply(preset)
                    } label: {
                        Text(preset.title)
                        Text(preset.detail)
                    }
                }
            } label: {
                Text("Load a Preset")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } footer: {
            Text(Caption.presets)
        }
        .disabled(!control.isEnabled)
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

    // MARK: - One band

    @ViewBuilder
    private func bandSection(_ band: EQBand) -> some View {
        Section {
            // The disable goes on the rows rather than the Section, or a switched
            // -out cut filter would disable its own switch in the header.
            Group {
                if band.kind.hasGain {
                    paramRow(title: "Gain", value: String(format: "%+.1f dB", band.gain)) {
                        Slider(value: Binding(get: { band.gain },
                                              set: { control.setGain($0, bandID: band.id) }),
                               in: Equalizer.gainRange)
                    }
                }
                paramRow(title: band.kind.isCut ? "Corner" : "Frequency",
                         value: frequencyLabel(band.frequency)) {
                    // Log-scaled: musical pitch is logarithmic, so a linear Hz slider
                    // wastes most of its travel on the top octave.
                    Slider(value: Binding(
                        get: { log10(Double(band.frequency)) },
                        set: { control.setFrequency(Float(pow(10.0, $0)), bandID: band.id) }),
                        in: log10(Double(band.frequencyRange.lowerBound))...log10(Double(band.frequencyRange.upperBound)))
                }
                if band.kind.hasQ {
                    // Shown and dragged as Q — what every EQ labels this control —
                    // while the model and the node keep octaves. Log-scaled like
                    // the frequency slider, and rightwards is narrower, as on every
                    // other EQ a DJ has touched.
                    paramRow(title: "Q", value: String(format: "%.2f", band.q)) {
                        Slider(value: Binding(
                            get: { log10(Double(band.q)) },
                            set: { control.setBandwidth(EQBandwidth.octaves(forQ: Float(pow(10.0, $0))),
                                                        bandID: band.id) }),
                            in: log10(Double(EQBandwidth.qRange.lowerBound))...log10(Double(EQBandwidth.qRange.upperBound)))
                    }
                }
            }
            .disabled(!control.isEnabled || (band.kind.isCut && !band.isEnabled))
        } header: {
            HStack {
                Text(band.name)
                    .foregroundStyle(band.id == selected ? Color.accentColor : Color.secondary)
                Spacer()
                if band.kind.isCut {
                    Toggle(band.name, isOn: Binding(
                        get: { band.isEnabled },
                        set: { control.setBandEnabled($0, bandID: band.id) }))
                        .labelsHidden()
                        .disabled(!control.isEnabled)
                }
            }
        } footer: {
            if !band.caption.isEmpty {
                Text(band.caption)
            }
        }
        .id(band.id)
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

/// Hoisted out of the body: long literals inside a view builder are what the
/// type-checker chokes on first.
private enum Caption {
    static let presets = """
        Golden Age is the starting point for electrical shellac, 1926–49: \
        bass and brilliance up, hiss down, both rails in. Post-1950 leaves \
        tape and vinyl alone. Then adjust by ear, and back off a little.
        """
}
