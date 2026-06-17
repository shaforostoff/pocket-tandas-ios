// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PeerLink.swift
//  Pocket Tandas
//
//  The wireless link between two phones, built on MultipeerConnectivity (which
//  uses Bluetooth + direct peer-to-peer Wi-Fi automatically, with no Wi-Fi
//  network required). The receiver advertises; the sender browses and invites.
//  Messages are JSON-encoded RemoteMessage values sent reliably.
//
//  Plain @Observable, not @MainActor (see observable-not-mainactor): the MC
//  delegate callbacks arrive off the main thread, so each hops to main before
//  mutating observed state or invoking callbacks.
//

import Foundation
import MultipeerConnectivity
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class PeerLink: NSObject {
    enum Role { case receiver, sender }

    enum ConnectionState: Equatable {
        case idle
        case advertising
        case browsing
        case connecting(String)
        case connected(String)
        case disconnected
    }

    /// Bonjour service type (≤15 chars, lowercase/digits/hyphen). Must match the
    /// NSBonjourServices entries in Info.plist.
    static let serviceType = "pt-djremote"

    private(set) var connectionState: ConnectionState = .idle
    private(set) var discoveredPeers: [MCPeerID] = []

    /// Invoked on the main thread for each decoded inbound message.
    @ObservationIgnored var onReceive: ((RemoteMessage) -> Void)?
    /// Invoked on the main thread when a peer connects (e.g. to (re)sync state).
    @ObservationIgnored var onConnected: ((MCPeerID) -> Void)?

    @ObservationIgnored private let role: Role
    @ObservationIgnored private let myPeerID: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    /// True while the link should be running, so an intentional stop() isn't
    /// undone by the auto-restart that a dropped connection triggers.
    @ObservationIgnored private var isActive = false

    init(role: Role) {
        self.role = role
        let peer = MCPeerID(displayName: Self.deviceName())
        self.myPeerID = peer
        self.session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    private static func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Pocket Tandas"
        #endif
    }

    // MARK: - Control (called from the main thread)

    func startAdvertising() {
        isActive = true
        stopDiscovery()
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
        setState(.advertising)
    }

    func startBrowsing() {
        isActive = true
        stopDiscovery()
        discoveredPeers = []
        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        setState(.browsing)
    }

    func invite(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 15)
        setState(.connecting(peer.displayName))
    }

    func disconnect() {
        session.disconnect()
    }

    func stop() {
        isActive = false
        stopDiscovery()
        session.disconnect()
        setState(.idle)
    }

    func send(_ message: RemoteMessage) {
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = message.encoded() else { return }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            ptLog("[PeerLink] send failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    /// After an unexpected drop, resume looking for the peer so the pair
    /// re-establishes on its own. Skipped after an intentional stop().
    private func restartDiscoveryAfterDrop() {
        guard isActive else { return }
        switch role {
        case .receiver: startAdvertising()
        case .sender: startBrowsing()
        }
    }

    private func setState(_ newState: ConnectionState) {
        if Thread.isMainThread {
            connectionState = newState
        } else {
            DispatchQueue.main.async { self.connectionState = newState }
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.stopDiscovery()            // 1:1 — no need to keep looking
                self.connectionState = .connected(peerID.displayName)
                self.onConnected?(peerID)
            case .connecting:
                self.connectionState = .connecting(peerID.displayName)
            case .notConnected:
                self.connectionState = .disconnected
                self.restartDiscoveryAfterDrop()
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = RemoteMessage.decode(data) else { return }
        DispatchQueue.main.async { self.onReceive?(message) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate (receiver)

extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept a single peer; reject further invitations to stay 1:1.
        let accept = session.connectedPeers.isEmpty
        invitationHandler(accept, accept ? session : nil)
        if accept { setState(.connecting(peerID.displayName)) }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        ptLog("[PeerLink] advertise error: \(error)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate (sender)

extension PeerLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.discoveredPeers.contains(peerID) { self.discoveredPeers.append(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        ptLog("[PeerLink] browse error: \(error)")
    }
}
