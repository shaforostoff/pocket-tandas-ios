// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RestorationSettingsView.swift
//  Pocket Tandas
//
//  The parameters overlay behind each restoration filter's "…" button in the EQ
//  panel. One sheet per filter, so the EQ panel itself stays a checkbox each.
//
//  Every default here is the one its algorithm was calibrated at against real
//  78 rpm transfers, so each control's caption says what moving it costs as well
//  as what it buys — see DSP/declick_core.h and DSP/dehum_core.h. Edits apply
//  live: both cores retune under a running stream without breaking the audio,
//  except Declick's Max repair and Model order, which resize its pipeline.
//
//  Like the EQ panel it came from, the same two forms edit either the local
//  filters or — in Remote Control mode — the receiver's, through whichever
//  RestorationControlling they were handed. Nothing here knows which.
//
//  The captions are `String` constants rather than literals in the body: a
//  ViewBuilder full of concatenated literals is expensive for the type checker,
//  and these are long.
//

import SwiftUI

/// Which filter's parameters a sheet is showing. `Identifiable` so the EQ panel
/// can drive one `.sheet(item:)` from both buttons.
enum RestorationFilter: String, Identifiable {
    case declick, dehum
    var id: String { rawValue }

    var title: String {
        switch self {
        case .declick: return "Declick"
        case .dehum: return "Dehum"
        }
    }
}

struct RestorationSettingsView: View {
    let filter: RestorationFilter
    let restoration: any RestorationControlling

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch filter {
                case .declick: DeclickSettingsForm(restoration: restoration)
                case .dehum: DehumSettingsForm(restoration: restoration)
                }
            }
            .navigationTitle(filter.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Captions

private enum Caption {
    static let declick = """
        Fits a model to the audio, finds the samples a click has broken, and \
        reconstructs what the waveform should have been there — rather than \
        smoothing over what is left.
        """
    static let declickDetection = """
        Sensitivity is the trigger, in robust sigmas: 0 % catches only \
        unmistakable clicks, 100 % starts costing real music. Extent is how far \
        a detection follows a click into its own tail.
        """
    static let declickRepair = """
        Depth at 0 % subtracts the fraction of each click that was measured to \
        add the least error of its own. Raising it removes more of the click but \
        substitutes more guesswork.
        """
    static let declickEffort = """
        A second pass catches clicks the first one uncovers, for roughly half as \
        much CPU again. Model order is the one control where spending CPU clearly \
        buys quality — 128 beats 64 measurably, and 256 beats that.
        """

    static let dehum = """
        Finds continuous narrowband tones — mains hum, and the off-frequency \
        drones speed-corrected disc transfers carry — and cancels each with a \
        notch narrow enough to leave the music either side of it alone.
        """
    static let dehumDetection = """
        Hum lives low. Searching further up finds sustained musical notes \
        instead: a held bandoneón E4 is as coherent a tone as any hum, and no \
        statistic computed from the signal can say otherwise.
        """
    static let dehumAutomatic = """
        The opening of each track is analysed in the background, so the line is \
        known from the first bar instead of from the first minute.
        """
    static let dehumPinned = """
        Pinned by hand: the search is off, and so is the background analysis.
        """
    static let dehumCancellation = """
        Harmonics are a mains-hum idea and cost music when they are not there — \
        multiples of a low fundamental land squarely in the musical register. \
        Raise it for a genuine mains buzz, where they do exist.
        """
    static let dehumRumble = """
        Broadband low-frequency rumble is a different defect from hum, but it \
        shares the band and it is what dominates some transfers. 67 Hz goes after \
        it properly and takes the bottom octave of a double bass with it; wind it \
        back towards 40 where the low end is worth keeping.
        """
}

// MARK: - Declick

private struct DeclickSettingsForm: View {
    let restoration: any RestorationControlling

    private var settings: DeclickSettings { restoration.declick }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Declick", isOn: Binding(
                    get: { restoration.declickEnabled },
                    set: { restoration.setDeclickEnabled($0) }))
            } footer: {
                Text(Caption.declick)
            }

            Section {
                RestorationSlider(title: "Sensitivity",
                                  value: binding(\.sensitivity) { $0.sensitivity = $1 },
                                  range: DeclickSettings.sensitivityRange,
                                  label: percent(settings.sensitivity))
                RestorationSlider(title: "Extent",
                                  value: binding(\.extent) { $0.extent = $1 },
                                  range: DeclickSettings.extentRange,
                                  label: percent(settings.extent))
            } header: {
                Text("Detection")
            } footer: {
                Text(Caption.declickDetection)
            }

            Section {
                RestorationSlider(title: "Max repair",
                                  value: binding(\.maxLengthMs) { $0.maxLengthMs = $1 },
                                  range: DeclickSettings.maxLengthRange,
                                  label: String(format: "%.1f ms", settings.maxLengthMs))
                RestorationSlider(title: "Depth",
                                  value: binding(\.depth) { $0.depth = $1 },
                                  range: DeclickSettings.depthRange,
                                  label: percent(settings.depth))
                RestorationSlider(title: "Dry/Wet",
                                  value: binding(\.dryWet) { $0.dryWet = $1 },
                                  range: DeclickSettings.dryWetRange,
                                  label: percent(settings.dryWet))
            } header: {
                Text("Repair")
            } footer: {
                Text(Caption.declickRepair)
            }

            Section {
                Stepper(value: Binding(get: { restoration.declick.passes },
                                       set: { new in restoration.updateDeclick { $0.passes = new } }),
                        in: DeclickSettings.passesRange) {
                    LabeledContent("Passes", value: "\(settings.passes)")
                }
                Stepper(value: Binding(get: { restoration.declick.order },
                                       set: { new in restoration.updateDeclick { $0.order = new } }),
                        in: DeclickSettings.orderRange, step: DeclickSettings.orderStep) {
                    LabeledContent("Model order", value: "\(settings.order)")
                }
            } header: {
                Text("Effort")
            } footer: {
                Text(Caption.declickEffort + latencyNote)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { restoration.resetDeclick() }
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// The one cost of having the node in the graph at all, quoted where the two
    /// controls that change it are.
    private var latencyNote: String {
        let ms = restoration.declickLatency * 1000
        guard ms > 0 else { return "" }
        let text = """
            The repair needs to see what comes after the samples it is fixing, so \
            the output runs %.0f ms behind the input at these settings. That delay \
            is held whether the filter is on or off, so switching it cannot click.
            """
        return "\n\n" + String(format: text, ms)
    }

    private func percent(_ value: Float) -> String { String(format: "%.0f %%", value * 100) }

    private func binding(_ get: KeyPath<DeclickSettings, Float>,
                         _ set: @escaping (inout DeclickSettings, Float) -> Void) -> Binding<Float> {
        Binding(get: { restoration.declick[keyPath: get] },
                set: { new in restoration.updateDeclick { set(&$0, new) } })
    }
}

// MARK: - Dehum

private struct DehumSettingsForm: View {
    let restoration: any RestorationControlling

    private var settings: DehumSettings { restoration.dehum }
    private var lines: [DehumLine] { restoration.detectedLines }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Dehum", isOn: Binding(
                    get: { restoration.dehumEnabled },
                    set: { restoration.setDehumEnabled($0) }))
            } footer: {
                Text(Caption.dehum)
            }

            detectedSection

            Section {
                RestorationSlider(title: "Sensitivity",
                                  value: binding(\.sensitivity) { $0.sensitivity = $1 },
                                  range: DehumSettings.sensitivityRange,
                                  label: String(format: "%.0f %%", settings.sensitivity * 100))
                RestorationSlider(title: "Search to",
                                  value: binding(\.searchTo) { $0.searchTo = $1 },
                                  range: DehumSettings.searchToRange,
                                  label: String(format: "%.0f Hz", settings.searchTo))
            } header: {
                Text("Detection")
            } footer: {
                Text(Caption.dehumDetection)
            }

            Section {
                Toggle("Detect automatically", isOn: Binding(
                    get: { restoration.dehum.isAutomatic },
                    set: { auto in restoration.updateDehum { $0.frequency = auto ? 0 : 50 } }))
                if !settings.isAutomatic {
                    RestorationSlider(title: "Line",
                                      value: binding(\.frequency) { $0.frequency = $1 },
                                      range: DehumSettings.frequencyRange,
                                      label: String(format: "%.1f Hz", settings.frequency))
                }
            } header: {
                Text("Frequency")
            } footer: {
                Text(settings.isAutomatic ? Caption.dehumAutomatic : Caption.dehumPinned)
            }

            Section {
                RestorationSlider(title: "Bandwidth",
                                  value: binding(\.bandwidth) { $0.bandwidth = $1 },
                                  range: DehumSettings.bandwidthRange,
                                  label: String(format: "%.2f Hz", settings.bandwidth))
                Stepper(value: Binding(get: { restoration.dehum.harmonics },
                                       set: { new in restoration.updateDehum { $0.harmonics = new } }),
                        in: DehumSettings.harmonicsRange) {
                    LabeledContent("Harmonics", value: "\(settings.harmonics)")
                }
                RestorationSlider(title: "Dry/Wet",
                                  value: binding(\.dryWet) { $0.dryWet = $1 },
                                  range: DehumSettings.dryWetRange,
                                  label: String(format: "%.0f %%", settings.dryWet * 100))
            } header: {
                Text("Cancellation")
            } footer: {
                Text(Caption.dehumCancellation)
            }

            Section {
                Toggle("High-pass filter", isOn: Binding(
                    get: { restoration.dehum.rumbleHz > 0 },
                    set: { on in restoration.updateDehum { $0.rumbleHz = on ? 67 : 0 } }))
                if settings.rumbleHz > 0 {
                    RestorationSlider(title: "Corner",
                                      value: binding(\.rumbleHz) { $0.rumbleHz = $1 },
                                      range: DehumSettings.rumbleRange,
                                      label: String(format: "%.0f Hz", settings.rumbleHz))
                }
            } header: {
                Text("Rumble")
            } footer: {
                Text(Caption.dehumRumble)
            }

            Section {
                Button("Reset to Defaults", role: .destructive) { restoration.resetDehum() }
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// What the detector is cancelling now — the receiver's detector, in Remote
    /// Control mode. Usually what the background scan of this track handed it,
    /// since that is where it got them from.
    @ViewBuilder
    private var detectedSection: some View {
        Section("Detected") {
            if lines.isEmpty {
                Label(scoutSummary, systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                ForEach(lines) { line in
                    lineRow(line)
                }
            }
        }
    }

    private func lineRow(_ line: DehumLine) -> some View {
        LabeledContent {
            Text(String(format: "%.1f dB", line.prominence))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.2f Hz", line.frequency)).monospacedDigit()
                Text(lineDetail(line)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lineDetail(_ line: DehumLine) -> String {
        let route = "found by " + line.routeLabel
        return line.harmonics > 1 ? route + " · \(line.harmonics) harmonics" : route
    }

    private var scoutSummary: String {
        guard restoration.dehumEnabled else { return "Switched off." }
        switch restoration.scoutPhase {
        case .scanning: return "Analysing this track…"
        case .foundNothing: return "Nothing steady enough to remove."
        case .found: return "Engaging…"
        case .skipped: return "No background analysis for this track."
        case .idle: return "Nothing playing."
        }
    }

    private func binding(_ get: KeyPath<DehumSettings, Float>,
                         _ set: @escaping (inout DehumSettings, Float) -> Void) -> Binding<Float> {
        Binding(get: { restoration.dehum[keyPath: get] },
                set: { new in restoration.updateDehum { set(&$0, new) } })
    }
}

// MARK: - Shared row

/// One labelled slider, laid out like the EQ panel's rows so the two overlays
/// read as one set of controls.
struct RestorationSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}
