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
//  SUSPENSION RECOVERY: with nothing playing there is no background audio to keep
//  the app alive, so locking the phone (or switching apps) suspends it and its
//  MultipeerConnectivity stack goes dead — the advertiser stops being visible and
//  neither it nor the MCSession recovers when the app is resumed. So on every
//  return to the foreground, if we aren't connected, the whole radio is rebuilt:
//  a fresh MCSession plus a fresh advertiser/browser (exactly what reopening the
//  screen used to do by hand).
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
    /// Invoked on the main thread when the peer drops (or an invitation fails), so
    /// mirrored state can be discarded rather than lingering as stale truth.
    @ObservationIgnored var onDisconnected: (() -> Void)?

    @ObservationIgnored private let role: Role
    @ObservationIgnored private let myPeerID: MCPeerID
    /// Recreated on foreground when a suspension has killed it — see the note above.
    @ObservationIgnored private var session: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    /// True while the link should be running, so an intentional stop() isn't
    /// undone by the auto-restart that a dropped connection triggers.
    @ObservationIgnored private var isActive = false
    /// Set while the app is in the background, so the return to the foreground knows
    /// the stack may have been suspended (and killed) meanwhile.
    @ObservationIgnored private var wasBackgrounded = false

    /// Sender only: the peer this screen was last connected to. Re-discovering it
    /// re-invites it without the DJ tapping anything — the phone locks, the link
    /// dies, and unlocking picks it back up. Cleared on a deliberate disconnect at
    /// either end, so "Disconnect" can't be undone a second later.
    @ObservationIgnored private var preferredPeerName: String?
    @ObservationIgnored private var lastAutoInviteAt: Date?
    /// An invitation has its own timeout; don't stack attempts on top of one.
    @ObservationIgnored private static let autoInviteCooldown: TimeInterval = 3
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    init(role: Role) {
        self.role = role
        let peer = MCPeerID(displayName: Self.deviceName())
        self.myPeerID = peer
        self.session = Self.makeSession(peer: peer)
        super.init()
        session.delegate = self
        observeLifecycle()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private static func makeSession(peer: MCPeerID) -> MCSession {
        MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
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

    /// User-initiated. Tell the peer it was deliberate — otherwise the sender's
    /// auto-reconnect would re-invite within the second — and drop the link a beat
    /// later so that message actually makes it out.
    func disconnect() {
        preferredPeerName = nil
        send(.goodbye)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.session.disconnect()
        }
    }

    func stop() {
        isActive = false
        preferredPeerName = nil
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

    // MARK: - Suspension recovery

    /// Rebuild the radio whenever the app returns from the BACKGROUND with no live
    /// connection: a suspension (lock screen, app switch) leaves the session and the
    /// advertiser/browser silently dead, and nothing short of new objects brings
    /// them back. Keyed on a real background transition, not on merely becoming
    /// active again — a Control Center pull or the local-network permission alert
    /// deactivates the app without harming the link, and rebuilding then would only
    /// cut off a handshake in progress.
    private func observeLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.wasBackgrounded = true
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.restartAfterForeground()
            },
        ]
        #endif
    }

    private func restartAfterForeground() {
        guard wasBackgrounded else { return }
        wasBackgrounded = false
        guard isActive, session.connectedPeers.isEmpty else { return }
        ptLog("[PeerLink] back from background with no peer — rebuilding the radio")
        rebuildSession()
        switch role {
        case .receiver: startAdvertising()
        case .sender: startBrowsing()
        }
    }

    /// Replace the MCSession. The old one's delegate is cleared first so its
    /// teardown can't report state for a session we no longer use.
    private func rebuildSession() {
        let old = session
        old.delegate = nil
        old.disconnect()
        session = Self.makeSession(peer: myPeerID)
        session.delegate = self
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
            guard session === self.session else { return }   // a rebuilt session's predecessor
            switch state {
            case .connected:
                self.stopDiscovery()            // 1:1 — no need to keep looking
                self.preferredPeerName = peerID.displayName
                self.connectionState = .connected(peerID.displayName)
                self.onConnected?(peerID)
            case .connecting:
                self.connectionState = .connecting(peerID.displayName)
            case .notConnected:
                self.connectionState = .disconnected
                self.onDisconnected?()
                self.restartDiscoveryAfterDrop()
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = RemoteMessage.decode(data) else { return }
        DispatchQueue.main.async {
            guard session === self.session else { return }
            // The peer is leaving deliberately — don't chase it.
            if case .goodbye = message { self.preferredPeerName = nil }
            self.onReceive?(message)
        }
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
            self.autoInviteIfPreferred(peerID)
        }
    }

    /// Re-invite the peer we were last connected to, and only that one: a DJ's phone
    /// must never latch onto whatever else happens to be advertising in the venue.
    private func autoInviteIfPreferred(_ peer: MCPeerID) {
        guard role == .sender, isActive,
              peer.displayName == preferredPeerName,
              session.connectedPeers.isEmpty else { return }
        if case .connecting = connectionState { return }
        if let last = lastAutoInviteAt, Date().timeIntervalSince(last) < Self.autoInviteCooldown { return }
        lastAutoInviteAt = Date()
        ptLog("[PeerLink] auto-reconnecting to \(peer.displayName)")
        invite(peer)
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
