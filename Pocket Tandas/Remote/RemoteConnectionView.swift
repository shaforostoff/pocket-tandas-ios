// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteConnectionView.swift
//  Pocket Tandas
//
//  The connection banner shown above the queue in the two remote modes. The
//  receiver just shows status; the sender also lists discovered peers to invite
//  until one is connected.
//
//  Once connected it folds away after ten seconds — a settled link needs no
//  running commentary, and the room is better spent on the queue. Any other state
//  (searching, connecting, dropped) brings it straight back, so its absence always
//  means "connected". It carries its own trailing Divider so the separator goes
//  with it.
//

import SwiftUI
import MultipeerConnectivity

struct RemoteConnectionView: View {
    let link: PeerLink
    let role: PeerLink.Role

    /// How long "Connected to …" stays up before the banner hides itself.
    private static let connectedLinger: Duration = .seconds(10)
    /// How long a search may go on before we offer the usual explanation.
    private static let hintDelay: Duration = .seconds(5)

    @State private var hideWhileConnected = false
    @State private var showRadioHint = false

    var body: some View {
        Group {
            if !(isConnected && hideWhileConnected) {
                banner
                Divider()
            }
        }
        // Restarts (and cancels the pending hide) on every state change, so a drop
        // or an explicit Disconnect shows the banner again immediately.
        .task(id: link.connectionState) {
            hideWhileConnected = false
            showRadioHint = false
            guard isConnected else {
                // Searching this long is nearly always one of the two radios being
                // off. Wi-Fi switched off in Settings drops the pair to Bluetooth,
                // which is slow — no network is needed, but the radio is.
                guard wantsRadioHint else { return }
                try? await Task.sleep(for: Self.hintDelay)
                guard !Task.isCancelled else { return }
                withAnimation { showRadioHint = true }
                return
            }
            try? await Task.sleep(for: Self.connectedLinger)
            guard !Task.isCancelled else { return }
            withAnimation { hideWhileConnected = true }
        }
    }

    private var banner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if isConnected {
                    Button("Disconnect") { link.disconnect() }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
            if role == .sender, !isConnected {
                peerPicker
            }
            // Re-checked at render, not just when the timer started: peers can turn
            // up while it runs, and that answers the question on its own.
            if showRadioHint, wantsRadioHint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Taking a while? Turn on Wi-Fi and Bluetooth on both phones — they connect directly, so no network is needed.")
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var peerPicker: some View {
        if link.discoveredPeers.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching for a controllable…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(link.discoveredPeers, id: \.self) { peer in
                        Button {
                            link.invite(peer)
                        } label: {
                            Label(peer.displayName, systemImage: "iphone")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    /// Idle means the link was deliberately shut down — nothing is searching, so
    /// there is nothing to explain. Nor is there once the sender is listing peers:
    /// finding one proves both radios are up, and the wait is now the DJ's own tap.
    private var wantsRadioHint: Bool {
        guard link.connectionState != .idle else { return false }
        if role == .sender, !link.discoveredPeers.isEmpty { return false }
        return true
    }

    private var isConnected: Bool {
        if case .connected = link.connectionState { return true }
        return false
    }

    private var statusText: String {
        switch link.connectionState {
        case .idle: return "Off"
        case .advertising: return "Waiting for a client to connect…"
        case .browsing: return "Searching for a controllable…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name): return "Connected to \(name)"
        case .disconnected: return role == .sender ? "Disconnected — searching…" : "Disconnected — waiting…"
        }
    }

    private var icon: String {
        isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    private var tint: Color {
        isConnected ? .green : .secondary
    }
}
