// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  PeerLink.swift
//  Pocket Tandas
//
//  The wireless link between two phones, built on Core Bluetooth: Bluetooth LE for
//  finding each other, and an L2CAP channel — a plain byte stream over the same
//  radio — for the messages. No Wi-Fi of any kind is involved.
//
//  WHY NOT MULTIPEERCONNECTIVITY (what this used to be): it races every path it can
//  find — infrastructure Wi-Fi, peer-to-peer Wi-Fi, Bluetooth — and on a phone that
//  is sharing a hotspot those paths fight over the one Wi-Fi radio, so a handshake
//  could take minutes. And it stops advertising the moment the app leaves the
//  foreground, even while background audio keeps the app running, so a receiver
//  whose screen had gone off could never be found again. BLE is allowed to keep
//  advertising in the background (`bluetooth-peripheral`), and a connection to a
//  known peripheral is a standing request that completes the moment it is back in
//  range.
//
//  Roles: the receiver is the GATT peripheral. It publishes an L2CAP channel and a
//  service with two readable characteristics — its identity (install id + name) and
//  the channel's PSM — and advertises the service. The sender is the central: it
//  scans for the service, reads the identity, reads the PSM and opens the channel.
//  The first frame on the channel is the sender's own identity ("hello"); the
//  receiver counts the link as up only once it arrives — and, from a phone it has
//  never let in, only once the DJ has allowed it (there is no pairing underneath).
//
//  Wire: each frame is [UInt32 big-endian length][UInt8 kind][body]. Kinds are a
//  heartbeat (empty), hello (identity JSON), message (a RemoteMessage encoding) and
//  file (a piece of a track being sent across: [UInt32 BE transfer id][bytes] —
//  raw, since base64 in JSON would add a third to the slowest thing on the link).
//  The receiver sends a heartbeat when it has been quiet for a few seconds and the
//  sender answers each one, so both ends notice a dead link within seconds — the
//  stream alone can sit open on a peer that has gone out of range.
//
//  Staying awake: iOS suspends a locked receiver within about a second of the
//  screen going off unless it is playing, and data arriving on the L2CAP channel
//  does not wake it — but a GATT read does (the bluetooth-peripheral background
//  mode). So while the channel is up the sender reads the one-byte wake
//  characteristic every couple of seconds, and each read buys the receiver another
//  few seconds to drain the channel and send its heartbeats. A wake read also
//  counts as hearing from the sender: a locked receiver doesn't reliably read the
//  sender's heartbeat answers off the channel, and without this it hit its silence
//  limit and closed an idle link every fifteen seconds.
//
//  Files over Wi-Fi: once the link is up the receiver offers a TCP lane over
//  peer-to-peer Wi-Fi (see WiFiLane), and file transfers go that way while it
//  works — about 25 KB/s on Bluetooth against megabytes a second. Everything else
//  stays on Bluetooth, and so does a file when there is no lane.
//
//  Reconnection: the sender remembers the last receiver it was connected to, across
//  launches, and re-joins it without a tap — by a standing connect to its
//  peripheral identifier and, since an unbonded phone's Bluetooth address rotates,
//  also by reading the identity of anything new it discovers. A deliberate
//  Disconnect at either end forgets it.
//
//  Plain @Observable, not @MainActor (see observable-not-mainactor). Both Core
//  Bluetooth managers deliver on the main queue and the channel streams are
//  scheduled on the main run loop, so all state here is touched on main only; only
//  message decoding happens off it.
//

import Foundation
import CoreBluetooth
import Network
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

/// The link's own log, kept in release builds too (unlike ptLog), so a TestFlight
/// build can be followed in Console.app: pick the phone, filter on category
/// "PeerLink". Public, or release builds show every interpolation as <private>.
private let peerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pocket Tandas", category: "PeerLink")

func linkLog(_ message: @autoclosure () -> String) {
    let text = message()
    peerLog.notice("\(text, privacy: .public)")
    #if DEBUG
    // stderr is unbuffered, so `devicectl … launch --console` shows each line as it
    // happens. Timestamped: gaps show where the app was suspended.
    fputs("[PeerLink] \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(text)\n", stderr)
    #endif
}

private extension CBManagerState {
    var name: String {
        switch self {
        case .unknown:      return "unknown"
        case .resetting:    return "resetting"
        case .unsupported:  return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff:   return "poweredOff"
        case .poweredOn:    return "poweredOn"
        @unknown default:   return "state \(rawValue)"
        }
    }
}

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
        /// Bluetooth is off, not permitted, or missing — the reason, for the banner.
        case unavailable(String)
    }

    /// A phone at the other end: a receiver as the sender sees it (id = its
    /// peripheral identifier), or a sender as the receiver sees it.
    struct Peer: Hashable, Identifiable {
        let id: UUID
        let displayName: String
    }

    private(set) var connectionState: ConnectionState = .idle
    /// Sender only: receivers heard recently, in the order first found.
    private(set) var discoveredPeers: [Peer] = []
    /// Receiver only: a sender this phone has never let in, waiting for the DJ to
    /// allow or refuse it. Nothing it sends is acted on meanwhile.
    private(set) var pendingSender: Peer?

    /// Invoked on the main thread for each decoded inbound message.
    @ObservationIgnored var onReceive: ((RemoteMessage) -> Void)?
    /// Invoked on the main thread when a peer connects (e.g. to (re)sync state).
    @ObservationIgnored var onConnected: ((Peer) -> Void)?
    /// Invoked on the main thread when the peer drops (or a connection attempt
    /// fails), so mirrored state can be discarded rather than lingering as stale truth.
    @ObservationIgnored var onDisconnected: (() -> Void)?
    /// Receiver: a piece of a file transfer, delivered on main in order with the
    /// messages around it — so a transfer's start always lands before its bytes.
    @ObservationIgnored var onFileChunk: ((Int, Data) -> Void)?
    /// Sender: everything queued has been handed to the stream. A file transfer
    /// feeds its next piece from here, which keeps at most a piece or two queued
    /// and lets a Stop the DJ taps meanwhile go out straight behind it.
    @ObservationIgnored var onOutboundDrained: (() -> Void)?
    /// Sender: the Wi-Fi lane failed while carrying these transfers' pieces, so
    /// they will never arrive complete — the file sender sends them again.
    @ObservationIgnored var onLaneTransfersLost: (([Int]) -> Void)?

    // MARK: GATT layout

    static let serviceUUID = CBUUID(string: "80CFC7CE-36B1-497E-9DD5-AC90F09BD31B")
    static let identityUUID = CBUUID(string: "9180F492-E7DF-45A0-B422-2BB8E20A4F93")
    /// Apple's conventional UUID for "the PSM of this service's L2CAP channel".
    static let psmUUID = CBUUID(string: CBUUIDL2CAPPSMCharacteristicString)
    /// Read only to wake a suspended receiver (see "Staying awake" above).
    static let wakeUUID = CBUUID(string: "D0CC63FF-F12F-4D02-AE94-059424F66CF6")

    /// Who is at an end of the link. The install id is what reconnection matches
    /// on: device names are no good for that, since without a special entitlement
    /// every iPhone reports its name as just "iPhone".
    struct Identity: Codable, Equatable {
        let id: UUID
        let name: String
    }

    // MARK: Timing

    /// The receiver sends a heartbeat after this long without sending anything.
    @ObservationIgnored private static let heartbeatInterval: TimeInterval = 3
    /// Either end declares the link dead after this long without hearing anything.
    @ObservationIgnored private static let silenceLimit: TimeInterval = 15
    /// A connection attempt that hasn't produced a working channel by now is dropped.
    @ObservationIgnored private static let attemptLimit: TimeInterval = 10
    /// A receiver not heard from in this long leaves the sender's picker.
    @ObservationIgnored private static let peerStaleAfter: TimeInterval = 12
    /// A receiver whose contact failed is tried again after this long.
    @ObservationIgnored private static let retryAfter: TimeInterval = 5
    @ObservationIgnored private static let tickInterval: TimeInterval = 1
    /// How often a connected link logs its byte counts.
    @ObservationIgnored private static let reportInterval: TimeInterval = 5
    @ObservationIgnored private var lastReport = Date.distantPast
    /// How often the sender reads the wake characteristic while the channel is up.
    @ObservationIgnored private static let wakeInterval: TimeInterval = 2
    @ObservationIgnored private var lastWake = Date.distantPast

    private static var appStateNote: String {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: return ""
        case .inactive: return ", app inactive"
        case .background: return ", app in background"
        @unknown default: return ""
        }
        #else
        return ""
        #endif
    }

    // MARK: State (both roles)

    @ObservationIgnored private let role: Role
    @ObservationIgnored private let identity: Identity
    /// True while the link should be running, so an intentional stop() isn't undone
    /// by the reconnection a dropped link triggers.
    @ObservationIgnored private var isActive = false
    /// The working channel — hello exchanged — and who is at its other end.
    @ObservationIgnored private var channel: FramedChannel?
    @ObservationIgnored private var channelPeer: Peer?
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "PeerLink.decode", qos: .userInitiated)

    // MARK: Wi-Fi lane

    /// What the receiver sends over Bluetooth to let the sender onto its lane.
    private struct LaneOffer: Codable {
        let service: String
        let token: Data
    }
    /// Receiver: the listener and the token a lane has to open with.
    @ObservationIgnored private var laneListener: WiFiLaneListener?
    @ObservationIgnored private var laneToken = Data()
    /// Receiver: connections that haven't shown the token yet.
    @ObservationIgnored private var laneCandidates: [WiFiLane] = []
    /// Sender: the receiver's offer, kept for retries.
    @ObservationIgnored private var laneOffer: LaneOffer?
    /// Sender: a lane connecting, and since when.
    @ObservationIgnored private var laneAttempt: (lane: WiFiLane, startedAt: Date)?
    @ObservationIgnored private var laneRetryAt = Date.distantPast
    /// The working lane: ready (sender) or past the token (receiver).
    @ObservationIgnored private var lane: WiFiLane?
    /// Sender: transfers whose pieces are going over the lane, until the
    /// receiver's result for them comes back.
    @ObservationIgnored private var laneTransfers: Set<Int> = []
    /// A lane with data waiting and no progress in this long has stalled.
    @ObservationIgnored private static let laneStallLimit: TimeInterval = 5
    /// After a lane fails, wait this long before trying again.
    @ObservationIgnored private static let laneRetryAfter: TimeInterval = 30
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: State (receiver)

    @ObservationIgnored private var peripheralManager: CBPeripheralManager?
    @ObservationIgnored private var serviceAdded = false
    /// The service and channel have been asked for and not yet confirmed, so a
    /// second publish() meanwhile doesn't add them twice.
    @ObservationIgnored private var publishInFlight = false
    @ObservationIgnored private var publishedPSM: CBL2CAPPSM?
    /// Channels opened by a sender that hasn't said hello yet, with when they opened.
    @ObservationIgnored private var unintroduced: [(channel: FramedChannel, openedAt: Date)] = []
    /// The channel behind `pendingSender`, kept alive with heartbeats while the DJ
    /// decides — a dialog can take longer than the sender's silence limit.
    @ObservationIgnored private var pending: (channel: FramedChannel, identity: Identity)?
    /// Persisted: install ids of the senders the DJ has allowed. The link has no
    /// encryption or pairing, so without this any phone in range running the app
    /// could stop the music, empty the queue, or write files into the library.
    @ObservationIgnored private var allowedSenders: Set<UUID> = PeerLink.loadAllowedSenders()

    // MARK: State (sender)

    @ObservationIgnored private var centralManager: CBCentralManager?
    /// Every peripheral we have heard of, retained (Core Bluetooth drops ours if we
    /// don't), with what we know about it.
    @ObservationIgnored private var known: [UUID: KnownPeripheral] = [:]
    /// The one peripheral we are talking GATT to right now, and why.
    @ObservationIgnored private var contact: Contact?
    /// A standing connect to the remembered receiver's last-known peripheral.
    @ObservationIgnored private var standingReconnect: CBPeripheral?
    /// Persisted: the receiver to re-join without a tap.
    @ObservationIgnored private var preferredReceiver: PreferredReceiver? {
        didSet { Self.savePreferred(preferredReceiver) }
    }

    private struct KnownPeripheral {
        let peripheral: CBPeripheral
        var advertisedName: String?
        var identity: Identity?
        var firstSeen: Date
        var lastSeen: Date
        /// Probed and found not to be the remembered receiver — don't keep connecting to it.
        var probeSettled = false
        /// The last contact with it failed: unreachable, or the phone answered but its
        /// app isn't serving the remote link (yet). Retried after `retryAfter`, never
        /// given up on — the receiver may simply not have been started.
        var failedAt: Date?

        func mayRetry(now: Date) -> Bool {
            failedAt.map { now.timeIntervalSince($0) > PeerLink.retryAfter } ?? true
        }
    }

    private struct Contact {
        enum Intent {
            /// Just read its identity (to name it, or to see if it's the remembered one).
            case probe
            /// The DJ picked it: join whatever it turns out to be.
            case join
            /// Join only if it is the remembered receiver.
            case rejoin
        }
        let peripheral: CBPeripheral
        var intent: Intent
        let startedAt: Date
        var identityCharacteristic: CBCharacteristic?
        var psmCharacteristic: CBCharacteristic?
        /// Nil on a receiver from before the wake characteristic existed.
        var wakeCharacteristic: CBCharacteristic?
        var identity: Identity?
        var psm: CBL2CAPPSM?
    }

    private struct PreferredReceiver: Codable {
        let identity: Identity
        var peripheralID: UUID
    }

    @ObservationIgnored private static let installIDKey = "PeerLink.installID"
    @ObservationIgnored private static let preferredKey = "PeerLink.preferredReceiver"
    @ObservationIgnored private static let allowedSendersKey = "PeerLink.allowedSenders"

    init(role: Role) {
        self.role = role
        self.identity = Identity(id: Self.installID(), name: Self.deviceName())
        self.preferredReceiver = role == .sender ? Self.loadPreferred() : nil
        super.init()
        observeLifecycle()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Control (called from the main thread)

    func startAdvertising() {
        linkLog("receiver: start (\(identity.name), install \(identity.id), \(allowedSenders.count) allowed senders)")
        isActive = true
        startTick()
        if let manager = peripheralManager {
            if manager.state == .poweredOn { publish() }
        } else {
            // Creating the manager is what asks for Bluetooth permission; its first
            // state update then publishes.
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main,
                                                    options: [CBPeripheralManagerOptionShowPowerAlertKey: true])
        }
        if channel == nil { setState(.advertising) }
    }

    func startBrowsing() {
        linkLog("sender: start (\(identity.name), install \(identity.id), remembered receiver: "
                + (preferredReceiver.map { "\($0.identity.name) at \($0.peripheralID)" } ?? "none") + ")")
        isActive = true
        startTick()
        discoveredPeers = []
        if let manager = centralManager {
            if manager.state == .poweredOn { beginSearch() }
        } else {
            centralManager = CBCentralManager(delegate: self, queue: .main,
                                              options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
        if channel == nil { setState(.browsing) }
    }

    /// Sender: the DJ tapped a receiver in the picker.
    func invite(_ peer: Peer) {
        guard role == .sender, let entry = known[peer.id] else {
            linkLog("invite: \(peer.displayName) (\(peer.id)) is no longer known")
            return
        }
        let peripheral = entry.peripheral
        linkLog("invite: the DJ picked \(peer.displayName) (\(peer.id))")
        if var current = contact, current.peripheral === peripheral {
            current.intent = .join
            contact = current
            // A probe doesn't read the PSM; ask now. The channel opens once both it
            // and the identity are in, in whichever order they land.
            proceedToChannel()
        } else {
            dropContact()
            beginContact(peripheral, intent: .join)
        }
        setState(.connecting(displayName(for: peripheral.identifier)))
    }

    /// User-initiated. Tell the peer it was deliberate — otherwise the sender's
    /// auto-reconnect would re-join within the second — and drop the link a beat
    /// later so that message actually makes it out.
    func disconnect() {
        linkLog("disconnect requested by the DJ")
        forgetPreferred()
        send(.goodbye)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.channelLost()
        }
    }

    /// Receiver: the DJ let the waiting sender in. Remembered, so it is never asked
    /// about again.
    func allowPendingSender() {
        guard let (framed, sender) = pending else { return }
        linkLog("allowed \(sender.name) (install \(sender.id))")
        pending = nil
        pendingSender = nil
        allowedSenders.insert(sender.id)
        UserDefaults.standard.set(allowedSenders.map(\.uuidString), forKey: Self.allowedSendersKey)
        introduce(framed, as: sender)
    }

    /// Receiver: the DJ turned the waiting sender away. A goodbye first, so it
    /// forgets this receiver instead of re-joining — and asking — every few seconds.
    func refusePendingSender() {
        guard let (framed, sender) = pending else { return }
        linkLog("refused \(sender.name)")
        pending = nil
        pendingSender = nil
        if let goodbye = RemoteMessage.goodbye.encoded() {
            framed.send(kind: .message, body: goodbye, droppable: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { framed.close() }
    }

    private func dropPendingSender() {
        pending?.channel.close()
        pending = nil
        pendingSender = nil
    }

    /// Leaving the screen. Keeps the remembered receiver, so coming back reconnects.
    func stop() {
        linkLog("\(role): stop")
        isActive = false
        tick?.invalidate()
        tick = nil
        channel?.close()
        channel = nil
        channelPeer = nil
        closeLane()
        unintroduced.forEach { $0.channel.close() }
        unintroduced = []
        dropPendingSender()
        switch role {
        case .receiver:
            if let manager = peripheralManager {
                manager.stopAdvertising()
                if let psm = publishedPSM { manager.unpublishL2CAPChannel(psm) }
                manager.removeAllServices()
            }
            publishedPSM = nil
            serviceAdded = false
            publishInFlight = false
        case .sender:
            centralManager?.stopScan()
            dropContact()
            if let standing = standingReconnect { centralManager?.cancelPeripheralConnection(standing) }
            standingReconnect = nil
            known = [:]
            discoveredPeers = []
        }
        setState(.idle)
    }

    /// Bytes queued on the channel and not yet written to it.
    var outboundBacklog: Int { (channel?.queuedBytes ?? 0) + (lane?.queuedBytes ?? 0) }

    /// One piece of a file transfer. False when there is no link to send it on.
    @discardableResult
    func sendFileChunk(transfer id: Int, bytes: Data) -> Bool {
        guard let channel else { return false }
        var body = Data(capacity: 4 + bytes.count)
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: id).bigEndian) { body.append(contentsOf: $0) }
        body.append(bytes)
        if let lane = lane(for: id) {
            lane.send(kind: .file, body: body)
        } else {
            channel.send(kind: .file, body: body, droppable: false)
        }
        return true
    }

    /// Where a transfer's frames go: the lane, if the transfer started on it and
    /// the lane is still up. A transfer starts on the lane whenever there is one.
    private func lane(for transfer: Int, starting: Bool = false) -> WiFiLane? {
        guard role == .sender, let lane else { return nil }
        if starting { laneTransfers.insert(transfer) }
        return laneTransfers.contains(transfer) ? lane : nil
    }

    func send(_ message: RemoteMessage) {
        guard let channel, let data = message.encoded() else { return }
        let laneForMessage: WiFiLane?
        switch message {
        case .fileStart(let start): laneForMessage = lane(for: start.id, starting: true)
        case .fileEnd(let id):      laneForMessage = lane(for: id)
        case .fileCancel(let id):
            laneForMessage = lane(for: id)
            laneTransfers.remove(id)
        default:                    laneForMessage = nil
        }
        if let laneForMessage {
            laneForMessage.send(kind: .message, body: data)
            return
        }
        // Position updates are superseded by the next one within seconds, so one
        // stuck behind a backlog is dropped rather than delivered stale.
        let droppable: Bool
        if case .progress = message { droppable = true } else { droppable = false }
        channel.send(kind: .message, body: data, droppable: droppable)
    }

    // MARK: - Shared plumbing

    private func startTick() {
        guard tick == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func onTick() {
        let now = Date()
        if let channel {
            if now.timeIntervalSince(lastReport) >= Self.reportInterval {
                lastReport = now
                linkLog("link: in \(channel.bytesRead / 1024) KB, out \(channel.bytesWritten / 1024) KB, "
                        + "queued \(channel.queuedBytes / 1024) KB, heard \(String(format: "%.1f", now.timeIntervalSince(channel.lastInbound)))s ago"
                        + Self.appStateNote)
            }
            if now.timeIntervalSince(channel.lastInbound) > Self.silenceLimit {
                linkLog("nothing heard for \(Int(Self.silenceLimit))s — link is dead")
                channelLost()
            } else if role == .receiver, now.timeIntervalSince(channel.lastOutbound) >= Self.heartbeatInterval {
                channel.send(kind: .heartbeat, body: Data(), droppable: true)
            } else if role == .sender, now.timeIntervalSince(lastWake) >= Self.wakeInterval,
                      let current = contact, let wake = current.wakeCharacteristic {
                lastWake = now
                current.peripheral.readValue(for: wake)
            }
            if role == .sender { tickLane(now) }
        }
        switch role {
        case .receiver:
            let expired = unintroduced.filter { now.timeIntervalSince($0.openedAt) > Self.attemptLimit }
            if !expired.isEmpty {
                linkLog("closing \(expired.count) channel(s) that never said hello")
                expired.forEach { $0.channel.close() }
                unintroduced.removeAll { entry in expired.contains { $0.channel === entry.channel } }
            }
            if let waiting = pending?.channel {
                if now.timeIntervalSince(waiting.lastInbound) > Self.silenceLimit {
                    linkLog("the sender waiting for the DJ went silent — dropping it")
                    dropPendingSender()
                } else if now.timeIntervalSince(waiting.lastOutbound) >= Self.heartbeatInterval {
                    waiting.send(kind: .heartbeat, body: Data(), droppable: true)
                }
            }
        case .sender:
            // The contact outlives its attempt — it stays set for as long as the
            // channel it produced is up — so only an attempt still without a channel
            // can time out.
            if channel == nil, let contact, now.timeIntervalSince(contact.startedAt) > Self.attemptLimit {
                linkLog("connection attempt to \(displayName(for: contact.peripheral.identifier)) timed out")
                contactFailed()
            }
            // Picks the remembered receiver and unknown ones back up once their
            // retry wait is over, even if no fresh sighting arrives to prompt it.
            if channel == nil, contact == nil {
                armStandingReconnect()
                probeNext()
            }
            refreshDiscoveredPeers(now: now)
        }
    }

    /// Wire up a channel (either role) and route its events here.
    private func makeFramed(_ l2cap: CBL2CAPChannel) -> FramedChannel {
        let framed = FramedChannel(l2cap)
        framed.onFrame = { [weak self, weak framed] kind, body in
            guard let self, let framed else { return }
            self.handleFrame(kind: kind, body: body, on: framed)
        }
        framed.onDrained = { [weak self, weak framed] in
            guard let self, let framed, framed === self.channel else { return }
            self.onOutboundDrained?()
        }
        framed.onClose = { [weak self, weak framed] in
            guard let self, let framed else { return }
            if framed === self.channel {
                linkLog("channel closed")
                self.channelLost()
            } else if framed === self.pending?.channel {
                linkLog("the sender waiting for the DJ closed its channel")
                self.dropPendingSender()   // it gave up waiting
            } else {
                linkLog("a channel closed before saying hello")
                self.unintroduced.removeAll { $0.channel === framed }
            }
        }
        return framed
    }

    private func handleFrame(kind: FramedChannel.Kind, body: Data, on framed: FramedChannel) {
        switch kind {
        case .heartbeat:
            // The sender answers; the receiver's own heartbeats are what it answers.
            if role == .sender, framed === channel {
                framed.send(kind: .heartbeat, body: Data(), droppable: true)
            }
        case .hello:
            guard role == .receiver, let peer = try? JSONDecoder().decode(Identity.self, from: body) else {
                linkLog("unreadable hello (\(body.count) bytes) — ignored")
                return
            }
            linkLog("hello from \(peer.name) (install \(peer.id))")
            introduce(framed, as: peer)
        case .message:
            guard framed === channel else { return }
            decodeQueue.async { [weak self] in
                guard let message = RemoteMessage.decode(body) else {
                    linkLog("undecodable message (\(body.count) bytes) — dropped")
                    return
                }
                DispatchQueue.main.async {
                    guard let self, framed === self.channel else { return }
                    // The peer is leaving deliberately — don't chase it.
                    if case .goodbye = message { self.forgetPreferred() }
                    if case .fileResult(let result) = message { self.laneTransfers.remove(result.id) }
                    self.onReceive?(message)
                }
            }
        case .lane:
            guard role == .sender, framed === channel,
                  let offer = try? JSONDecoder().decode(LaneOffer.self, from: body) else { return }
            linkLog("Wi-Fi lane offered (\(offer.service))")
            closeLane()
            laneOffer = offer
            connectLane()
        case .file:
            guard framed === channel, body.count >= 4 else { return }
            let id = Int(body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let bytes = body.dropFirst(4)
            // Through the decode queue too, purely to stay in order behind the
            // message that announced the transfer.
            decodeQueue.async { [weak self] in
                DispatchQueue.main.async {
                    guard let self, framed === self.channel else { return }
                    self.onFileChunk?(id, Data(bytes))
                }
            }
        }
    }

    /// The working channel went away — closed, silent too long, or disconnected on
    /// purpose. Report it, then go back to waiting / searching.
    private func channelLost() {
        guard let lost = channel else { return }
        linkLog("link to \(channelPeer?.displayName ?? "?") lost")
        lost.close()
        closeLane()
        channel = nil
        channelPeer = nil
        setState(isActive ? .disconnected : .idle)
        onDisconnected?()
        guard role == .sender else { return }
        // Tear down the GATT link too, so the reconnect starts from a clean connect;
        // didDisconnect then re-arms the standing reconnect if we still want it.
        // The contact goes now, not in didDisconnect: left in place, its old start
        // time would read as a timed-out attempt on the next tick.
        if let contact, contact.peripheral.state != .disconnected {
            self.contact = nil
            centralManager?.cancelPeripheralConnection(contact.peripheral)
        } else {
            self.contact = nil
            beginSearch()
        }
    }

    private func setState(_ newState: ConnectionState) {
        guard connectionState != newState else { return }
        linkLog("state: \(connectionState) → \(newState)")
        connectionState = newState
    }

    private func observeLifecycle() {
        #if canImport(UIKit)
        // Scanning is throttled while the sender is in the background; on return,
        // restart it and the standing connect so the link comes back at once
        // instead of on the next slow background discovery window.
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isActive, self.role == .sender, self.channel == nil else { return }
                linkLog("back in the foreground — searching again")
                self.beginSearch()
            },
        ]
        #endif
    }

    // MARK: - Identity persistence

    private static func installID() -> UUID {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: installIDKey), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: installIDKey)
        return id
    }

    private static func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Pocket Tandas"
        #endif
    }

    private static func loadPreferred() -> PreferredReceiver? {
        guard let data = UserDefaults.standard.data(forKey: preferredKey) else { return nil }
        return try? JSONDecoder().decode(PreferredReceiver.self, from: data)
    }

    private static func loadAllowedSenders() -> Set<UUID> {
        let stored = UserDefaults.standard.stringArray(forKey: allowedSendersKey) ?? []
        return Set(stored.compactMap(UUID.init(uuidString:)))
    }

    private static func savePreferred(_ preferred: PreferredReceiver?) {
        if let preferred, let data = try? JSONEncoder().encode(preferred) {
            UserDefaults.standard.set(data, forKey: preferredKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferredKey)
        }
    }

    private func forgetPreferred() {
        guard role == .sender else { return }
        preferredReceiver = nil
        if let standing = standingReconnect, standing !== contact?.peripheral {
            centralManager?.cancelPeripheralConnection(standing)
        }
        standingReconnect = nil
    }
}

// MARK: - Receiver (peripheral)

extension PeerLink: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        linkLog("receiver: Bluetooth \(peripheral.state.name), authorization \(CBManager.authorization.rawValue), active \(isActive)")
        switch peripheral.state {
        case .poweredOn:
            guard isActive else { return }
            publish()
            if channel == nil { setState(.advertising) }
        default:
            // Services and the published channel don't survive the radio going down;
            // publish() starts over when it comes back.
            serviceAdded = false
            publishedPSM = nil
            publishInFlight = false
            unintroduced.forEach { $0.channel.close() }
            unintroduced = []
            dropPendingSender()
            channelLost()
            if isActive, let reason = Self.unavailableReason(peripheral.state) { setState(.unavailable(reason)) }
        }
    }

    private func publish() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }
        if !serviceAdded && publishedPSM == nil && !publishInFlight {
            linkLog("publishing the service and the L2CAP channel")
            publishInFlight = true
            manager.removeAllServices()
            let identityChar = CBMutableCharacteristic(type: Self.identityUUID, properties: [.read],
                                                       value: nil, permissions: [.readable])
            let psmChar = CBMutableCharacteristic(type: Self.psmUUID, properties: [.read],
                                                  value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            // No cached value: Core Bluetooth would answer a cached one by itself,
            // without waking the app — and waking the app is the point.
            let wakeChar = CBMutableCharacteristic(type: Self.wakeUUID, properties: [.read],
                                                   value: nil, permissions: [.readable])
            service.characteristics = [identityChar, psmChar, wakeChar]
            manager.add(service)
            // No link-level encryption: that would mean a pairing prompt on both
            // phones, for a DJ's queue and transport commands between two phones in
            // the same room.
            manager.publishL2CAPChannel(withEncryption: false)
        }
        startAdvertisingIfReady()
    }

    private func startAdvertisingIfReady() {
        guard let manager = peripheralManager, serviceAdded, publishedPSM != nil,
              !manager.isAdvertising else { return }
        // The name only travels while in the foreground; in the background iOS keeps
        // just the service UUID, and the sender reads the name from the identity
        // characteristic instead.
        linkLog("advertising as \(identity.name), PSM \(publishedPSM.map(String.init) ?? "?")")
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                  CBAdvertisementDataLocalNameKey: identity.name])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            linkLog("adding the service failed: \(error)")
            publishInFlight = false   // the next startAdvertising() tries again
            return
        }
        linkLog("service added")
        serviceAdded = true
        publishInFlight = publishedPSM == nil
        startAdvertisingIfReady()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            linkLog("publishing the channel failed: \(error)")
            publishInFlight = false   // the next startAdvertising() tries again
            return
        }
        linkLog("L2CAP channel published on PSM \(PSM)")
        publishedPSM = PSM
        publishInFlight = !serviceAdded
        startAdvertisingIfReady()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { linkLog("advertise error: \(error)") } else { linkLog("advertising started") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Every couple of seconds while linked, so not logged.
        if request.characteristic.uuid == Self.wakeUUID {
            for framed in [channel, pending?.channel].compactMap({ $0 })
            where framed.peerIdentifier == request.central.identifier {
                framed.heard()
            }
            request.value = Data([0])
            return peripheral.respond(to: request, withResult: .success)
        }
        let value: Data?
        switch request.characteristic.uuid {
        case Self.identityUUID: value = try? JSONEncoder().encode(identity)
        case Self.psmUUID:      value = publishedPSM.map { withUnsafeBytes(of: $0.littleEndian) { Data($0) } }
        default:                value = nil
        }
        linkLog("read of \(request.characteristic.uuid) at offset \(request.offset) from central \(request.central.identifier)"
                + (value == nil ? " — nothing to give" : ""))
        guard let value else { return peripheral.respond(to: request, withResult: .attributeNotFound) }
        guard request.offset <= value.count else { return peripheral.respond(to: request, withResult: .invalidOffset) }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel else {
            if let error { linkLog("incoming channel failed: \(error)") }
            return
        }
        linkLog("incoming channel on PSM \(channel.psm) from \(channel.peer?.identifier.uuidString ?? "?")"
                + (isActive ? "" : " — not active, ignored"))
        guard isActive else { return }
        unintroduced.append((makeFramed(channel), Date()))
    }

    /// A sender said hello. Stay 1:1: a second phone is turned away while the
    /// current link is alive — but not when the current one has gone quiet, or when
    /// the hello is from that same phone, which then is just coming back from a link
    /// that died without us noticing yet. A phone never let in before waits for the
    /// DJ first (`pendingSender`); a newer one replaces it in the wait.
    private func introduce(_ framed: FramedChannel, as peer: Identity) {
        unintroduced.removeAll { $0.channel === framed }
        guard allowedSenders.contains(peer.id) else {
            linkLog("\(peer.name) asks to connect — waiting for the DJ")
            dropPendingSender()
            pending = (framed, peer)
            pendingSender = Peer(id: peer.id, displayName: peer.name)
            return
        }
        if let current = channel {
            let sameSender = channelPeer.map { $0.id == peer.id } ?? false
            let quiet = Date().timeIntervalSince(current.lastInbound) > Self.heartbeatInterval * 2
            guard sameSender || quiet else {
                linkLog("turning away \(peer.name) — already connected")
                framed.close()
                return
            }
            linkLog("\(peer.name) replaces the current link")
            // close() silences the channel's own onClose, so report the drop here:
            // a transfer the old sender left half-sent must not outlive it.
            current.close()
            onDisconnected?()
        }
        let connected = Peer(id: peer.id, displayName: peer.name)
        linkLog("link up with \(peer.name)")
        channel = framed
        channelPeer = connected
        setState(.connected(peer.name))
        onConnected?(connected)
        openLane()
    }

    fileprivate static func unavailableReason(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOff:   return "Bluetooth is off"
        case .unauthorized: return "Bluetooth access is off for Pocket Tandas in Settings"
        case .unsupported:  return "This device has no Bluetooth LE"
        default:            return nil     // unknown / resetting: transient
        }
    }
}

// MARK: - Sender (central)

extension PeerLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        linkLog("sender: Bluetooth \(central.state.name), authorization \(CBManager.authorization.rawValue), active \(isActive)")
        switch central.state {
        case .poweredOn:
            guard isActive else { return }
            if channel == nil { setState(.browsing) }
            beginSearch()
        default:
            contact = nil
            standingReconnect = nil
            known = [:]
            discoveredPeers = []
            channelLost()
            if isActive, let reason = Self.unavailableReason(central.state) { setState(.unavailable(reason)) }
        }
    }

    /// Scan, and keep a standing connect open to the remembered receiver. Both are
    /// harmless to repeat.
    private func beginSearch() {
        guard role == .sender, isActive, channel == nil,
              let central = centralManager, central.state == .poweredOn else { return }
        // Duplicates on: the picker drops receivers that stop being heard, and that
        // needs a steady stream of sightings. Scanning stops once connected.
        if !central.isScanning { linkLog("scanning for receivers") }
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        armStandingReconnect()
        probeNext()
    }

    private func armStandingReconnect() {
        guard let preferred = preferredReceiver, let central = centralManager,
              contact == nil, standingReconnect == nil,
              known[preferred.peripheralID]?.mayRetry(now: Date()) ?? true,
              let peripheral = central.retrievePeripherals(withIdentifiers: [preferred.peripheralID]).first
        else { return }
        linkLog("standing connect to \(preferred.identity.name) at \(peripheral.identifier)")
        remember(peripheral, seen: false)
        standingReconnect = peripheral
        // No timeout: this completes whenever the receiver is next reachable.
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isActive else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Duplicates are on, so only the first sighting of each is logged.
        if known[peripheral.identifier].map({ $0.lastSeen == .distantPast }) ?? true {
            linkLog("discovered \(advertisedName ?? "unnamed receiver") at \(peripheral.identifier), RSSI \(RSSI)")
        }
        remember(peripheral, advertisedName: advertisedName)
        refreshDiscoveredPeers(now: Date())
        guard channel == nil else { return }
        // The remembered receiver, under a peripheral id we already recognise — or
        // under its remembered id while the identity is still unread, as when the
        // last contact reached the phone before its app was serving.
        if let preferred = preferredReceiver,
           known[peripheral.identifier]?.identity?.id == preferred.identity.id
            || (peripheral.identifier == preferred.peripheralID && known[peripheral.identifier]?.identity == nil),
           contact?.peripheral !== peripheral,
           known[peripheral.identifier]?.mayRetry(now: Date()) ?? true {
            if let current = contact, current.intent == .join { return }  // the DJ's pick wins
            dropContact()
            beginContact(peripheral, intent: .rejoin)
            return
        }
        probeNext()
    }

    /// `seen` is false for a peripheral we only looked up by identifier: it is
    /// retained, but stays out of the picker until it is actually heard.
    private func remember(_ peripheral: CBPeripheral, advertisedName: String? = nil, seen: Bool = true) {
        let now = Date()
        let lastSeen = seen ? now : .distantPast
        if var entry = known[peripheral.identifier] {
            if seen { entry.lastSeen = now }
            if let advertisedName { entry.advertisedName = advertisedName }
            known[peripheral.identifier] = entry
        } else {
            known[peripheral.identifier] = KnownPeripheral(peripheral: peripheral, advertisedName: advertisedName,
                                                           firstSeen: now, lastSeen: lastSeen)
        }
    }

    /// Read the identity of one unknown receiver at a time: to put a name on one
    /// that is advertising from the background (no name in its advert then), and to
    /// recognise the remembered receiver under a rotated Bluetooth address.
    private func probeNext() {
        guard role == .sender, isActive, channel == nil, contact == nil else { return }
        let now = Date()
        let candidate = known.values
            .filter { !$0.probeSettled && $0.identity == nil && $0.mayRetry(now: now)
                && now.timeIntervalSince($0.lastSeen) < Self.peerStaleAfter
                && ($0.advertisedName == nil || preferredReceiver != nil) }
            .min { $0.firstSeen < $1.firstSeen }
        guard let candidate else { return }
        beginContact(candidate.peripheral, intent: .probe)
    }

    private func beginContact(_ peripheral: CBPeripheral, intent: Contact.Intent) {
        contact = Contact(peripheral: peripheral, intent: intent, startedAt: Date())
        linkLog("contact (\(intent)) with \(displayName(for: peripheral.identifier)) at \(peripheral.identifier)"
                + (peripheral.state == .connected ? ", already connected" : ", connecting"))
        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.serviceUUID])
        } else {
            centralManager?.connect(peripheral)
        }
    }

    /// Abandon the current contact without reporting anything.
    private func dropContact() {
        guard let current = contact else { return }
        contact = nil
        if current.peripheral !== standingReconnect {
            centralManager?.cancelPeripheralConnection(current.peripheral)
        }
    }

    /// The current contact didn't work out. A probe just moves on; a join the DJ
    /// is waiting on is reported.
    private func contactFailed() {
        guard let failed = contact else { return }
        linkLog("contact (\(failed.intent)) with \(displayName(for: failed.peripheral.identifier)) failed")
        known[failed.peripheral.identifier]?.failedAt = Date()
        dropContact()
        if failed.intent != .probe {
            if channel == nil { setState(.disconnected) }
            onDisconnected?()
        }
        beginSearch()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        linkLog("connected to \(peripheral.identifier)" + (peripheral === standingReconnect ? " (standing connect)" : ""))
        if peripheral === standingReconnect {
            standingReconnect = nil
            if contact?.peripheral !== peripheral {
                if let current = contact, current.intent == .join {
                    central.cancelPeripheralConnection(peripheral)   // the DJ picked another
                    return
                }
                dropContact()
                contact = Contact(peripheral: peripheral, intent: .rejoin, startedAt: Date())
            }
        }
        guard let current = contact, current.peripheral === peripheral else {
            linkLog("not the current contact — disconnecting \(peripheral.identifier)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if current.intent != .probe { setState(.connecting(displayName(for: peripheral.identifier))) }
        linkLog("discovering services on \(peripheral.identifier)")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        linkLog("connect failed: \(error.map { "\($0)" } ?? "no reason")")
        if peripheral === standingReconnect { standingReconnect = nil }
        if contact?.peripheral === peripheral { contactFailed() } else { beginSearch() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        linkLog("disconnected from \(peripheral.identifier): \(error.map { "\($0)" } ?? "on request")")
        if peripheral === standingReconnect { standingReconnect = nil }
        if contact?.peripheral === peripheral {
            contact = nil
            if channel != nil { channelLost() }
        }
        // Re-arms the standing connect on the remembered receiver, so it comes back
        // the moment it is reachable (or via the scan, if its address rotated).
        beginSearch()
    }

    private func proceedToChannel() {
        guard let current = contact, let psmChar = current.psmCharacteristic else { return }
        linkLog("reading the PSM")
        current.peripheral.readValue(for: psmChar)
    }

    private func refreshDiscoveredPeers(now: Date) {
        let peers = known.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.peerStaleAfter }
            .sorted { $0.firstSeen < $1.firstSeen }
            .map { Peer(id: $0.peripheral.identifier, displayName: displayName(for: $0.peripheral.identifier)) }
        if peers != discoveredPeers { discoveredPeers = peers }
    }

    private func displayName(for peripheralID: UUID) -> String {
        known[peripheralID]?.identity?.name ?? known[peripheralID]?.advertisedName ?? "Nearby phone"
    }
}

extension PeerLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard contact?.peripheral === peripheral else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            linkLog("\(peripheral.identifier) has no remote service: \(error.map { "\($0)" } ?? "")")
            return contactFailed()
        }
        linkLog("found the remote service; discovering its characteristics")
        peripheral.discoverCharacteristics([Self.identityUUID, Self.psmUUID, Self.wakeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard var current = contact, current.peripheral === peripheral else { return }
        let chars = service.characteristics ?? []
        current.identityCharacteristic = chars.first { $0.uuid == Self.identityUUID }
        current.psmCharacteristic = chars.first { $0.uuid == Self.psmUUID }
        current.wakeCharacteristic = chars.first { $0.uuid == Self.wakeUUID }
        contact = current
        guard let identityChar = current.identityCharacteristic, let psmChar = current.psmCharacteristic else {
            linkLog("characteristics missing (got \(chars.map(\.uuid)), error \(error.map { "\($0)" } ?? "none"))")
            return contactFailed()
        }
        linkLog("reading the identity" + (current.intent == .join ? " and the PSM" : ""))
        peripheral.readValue(for: identityChar)
        // A join doesn't need to wait for the identity to know it wants the PSM.
        if current.intent == .join { peripheral.readValue(for: psmChar) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard var current = contact, current.peripheral === peripheral else { return }
        // A wake read did its job by reaching the receiver; a failed one is left to
        // the silence limit, not treated as a failed contact.
        if characteristic.uuid == Self.wakeUUID {
            if let error { linkLog("wake read failed: \(error)") }
            return
        }
        guard error == nil, let value = characteristic.value else {
            linkLog("reading \(characteristic.uuid) failed: \(error.map { "\($0)" } ?? "empty")")
            return contactFailed()
        }
        switch characteristic.uuid {
        case Self.identityUUID:
            guard let peer = try? JSONDecoder().decode(Identity.self, from: value) else {
                linkLog("unreadable identity (\(value.count) bytes)")
                return contactFailed()
            }
            linkLog("identity: \(peer.name) (install \(peer.id))"
                    + (preferredReceiver?.identity.id == peer.id ? ", the remembered receiver" : ""))
            current.identity = peer
            known[peripheral.identifier]?.identity = peer
            refreshDiscoveredPeers(now: Date())
            let isPreferred = preferredReceiver?.identity.id == peer.id
            switch current.intent {
            case .join:
                contact = current
                openChannelIfReady()
            case .rejoin where isPreferred, .probe where isPreferred:
                current.intent = .rejoin
                contact = current
                setState(.connecting(peer.name))
                proceedToChannel()
            case .rejoin, .probe:
                // Named now, and not the one we'd re-join: leave it for the DJ.
                known[peripheral.identifier]?.probeSettled = true
                dropContact()
                probeNext()
            }
        case Self.psmUUID:
            guard value.count >= 2 else {
                linkLog("PSM too short (\(value.count) bytes)")
                return contactFailed()
            }
            current.psm = CBL2CAPPSM(value[value.startIndex]) | CBL2CAPPSM(value[value.startIndex + 1]) << 8
            linkLog("PSM: \(current.psm!)")
            contact = current
            openChannelIfReady()
        default:
            break
        }
    }

    /// Both the identity and the PSM are in: open the channel.
    private func openChannelIfReady() {
        guard let current = contact, current.intent != .probe,
              current.identity != nil, let psm = current.psm else { return }
        linkLog("opening the L2CAP channel on PSM \(psm)")
        current.peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen l2cap: CBL2CAPChannel?, error: Error?) {
        guard let current = contact, current.peripheral === peripheral, let receiver = current.identity else { return }
        guard let l2cap else {
            linkLog("opening the channel failed: \(error.map { "\($0)" } ?? "no reason")")
            return contactFailed()
        }
        let framed = makeFramed(l2cap)
        guard let hello = try? JSONEncoder().encode(identity) else { return contactFailed() }
        linkLog("channel open; saying hello")
        framed.send(kind: .hello, body: hello, droppable: false)
        centralManager?.stopScan()
        if let standing = standingReconnect, standing !== peripheral {
            centralManager?.cancelPeripheralConnection(standing)
        }
        standingReconnect = nil
        preferredReceiver = PreferredReceiver(identity: receiver, peripheralID: peripheral.identifier)
        let connected = Peer(id: peripheral.identifier, displayName: receiver.name)
        channel = framed
        channelPeer = connected
        linkLog("connected to \(receiver.name) in \(String(format: "%.2f", Date().timeIntervalSince(current.startedAt)))s")
        setState(.connected(receiver.name))
        onConnected?(connected)
    }
}

// MARK: - Wi-Fi lane

extension PeerLink {
    /// Receiver: listen for the sender's lane, and offer it once listening. A new
    /// Bluetooth link gets a new listener and a new token.
    fileprivate func openLane() {
        guard role == .receiver else { return }
        closeLane()
        let token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let listener: WiFiLaneListener
        do { listener = try WiFiLaneListener() } catch {
            return linkLog("Wi-Fi lane: can't listen: \(error)")
        }
        laneToken = token
        laneListener = listener
        listener.onReady = { [weak self, weak listener] in
            guard let self, let listener, listener === self.laneListener, let channel = self.channel,
                  let body = try? JSONEncoder().encode(LaneOffer(service: listener.name, token: token)) else { return }
            linkLog("Wi-Fi lane listening as \(listener.name); offering it")
            channel.send(kind: .lane, body: body, droppable: false)
        }
        listener.onFailed = { reason in linkLog("Wi-Fi lane listener failed: \(reason)") }
        listener.onConnection = { [weak self] connection in self?.admitLane(connection) }
    }

    /// Receiver: a connection gets in by opening with the token.
    private func admitLane(_ connection: NWConnection) {
        let candidate = WiFiLane(connection)
        laneCandidates.append(candidate)
        candidate.onClose = { [weak self, weak candidate] _ in
            self?.laneCandidates.removeAll { $0 === candidate }
        }
        candidate.onFrame = { [weak self, weak candidate] kind, body in
            guard let self, let candidate else { return }
            self.laneCandidates.removeAll { $0 === candidate }
            guard kind == .hello, body == self.laneToken, self.channel != nil else {
                linkLog("Wi-Fi lane: a connection without the token — closed")
                return candidate.close()
            }
            self.lane?.close()
            self.lane = candidate
            linkLog("Wi-Fi lane up (\(candidate.path))")
            candidate.onFrame = { [weak self] kind, body in self?.handleLaneFrame(kind, body) }
            candidate.onClose = { [weak self, weak candidate] reason in
                guard let self, let candidate, candidate === self.lane else { return }
                linkLog("Wi-Fi lane closed: \(reason)")
                self.lane = nil
            }
        }
    }

    /// Receiver: messages and pieces off the lane, through the decode queue like
    /// the channel's so each transfer's start lands before its bytes.
    private func handleLaneFrame(_ kind: WiFiLane.Kind, _ body: Data) {
        switch kind {
        case .hello:
            return
        case .message:
            decodeQueue.async { [weak self] in
                guard let message = RemoteMessage.decode(body) else {
                    return linkLog("undecodable lane message (\(body.count) bytes) — dropped")
                }
                DispatchQueue.main.async {
                    guard let self, self.channel != nil else { return }
                    self.onReceive?(message)
                }
            }
        case .file:
            guard body.count >= 4 else { return }
            let id = Int(body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let bytes = body.dropFirst(4)
            decodeQueue.async { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.channel != nil else { return }
                    self.onFileChunk?(id, Data(bytes))
                }
            }
        }
    }

    /// Sender: connect to the offered lane; it counts once it is ready, and opens
    /// with the token.
    fileprivate func connectLane() {
        guard role == .sender, lane == nil, laneAttempt == nil, channel != nil, let offer = laneOffer else { return }
        linkLog("Wi-Fi lane: connecting to \(offer.service)")
        let attempt = WiFiLane(service: offer.service)
        laneAttempt = (attempt, Date())
        attempt.onReady = { [weak self, weak attempt] in
            guard let self, let attempt, attempt === self.laneAttempt?.lane else { return }
            self.laneAttempt = nil
            attempt.send(kind: .hello, body: offer.token)
            self.lane = attempt
            linkLog("Wi-Fi lane up (\(attempt.path)) — files go this way")
        }
        attempt.onDrained = { [weak self] in self?.onOutboundDrained?() }
        attempt.onClose = { [weak self, weak attempt] reason in
            guard let self, let attempt else { return }
            if attempt === self.lane {
                self.laneLost("closed: \(reason)")
            } else if attempt === self.laneAttempt?.lane {
                linkLog("Wi-Fi lane: couldn't connect: \(reason)")
                self.laneAttempt = nil
                self.laneRetryAt = Date().addingTimeInterval(Self.laneRetryAfter)
            }
        }
    }

    /// Sender, each tick: give up on a slow attempt, notice a stalled lane, retry.
    fileprivate func tickLane(_ now: Date) {
        if let attempt = laneAttempt, now.timeIntervalSince(attempt.startedAt) > Self.attemptLimit {
            linkLog("Wi-Fi lane: no connection after \(Int(Self.attemptLimit))s — staying on Bluetooth")
            attempt.lane.close()
            laneAttempt = nil
            laneRetryAt = now.addingTimeInterval(Self.laneRetryAfter)
        }
        if let lane, lane.queuedBytes > 0, now.timeIntervalSince(lane.lastProgress) > Self.laneStallLimit {
            laneLost("stalled for \(Int(Self.laneStallLimit))s")
        }
        if lane == nil, laneAttempt == nil, laneOffer != nil, now >= laneRetryAt {
            connectLane()
        }
    }

    /// Sender: the lane is gone. A transfer whose pieces were on it can't finish;
    /// the file sender sends it again, over Bluetooth until a lane is back.
    private func laneLost(_ reason: String) {
        guard let lost = lane else { return }
        linkLog("Wi-Fi lane lost (\(reason)) — back to Bluetooth")
        lost.close()
        lane = nil
        laneRetryAt = Date().addingTimeInterval(Self.laneRetryAfter)
        let stranded = Array(laneTransfers)
        laneTransfers = []
        if !stranded.isEmpty { onLaneTransfersLost?(stranded) }
    }

    /// Both roles: the Bluetooth link is gone or being replaced, and the lane with it.
    fileprivate func closeLane() {
        laneListener?.cancel()
        laneListener = nil
        laneCandidates.forEach { $0.close() }
        laneCandidates = []
        laneAttempt?.lane.close()
        laneAttempt = nil
        lane?.close()
        lane = nil
        laneOffer = nil
        laneTransfers = []
        laneRetryAt = .distantPast
    }
}

// MARK: - Framed channel

/// One L2CAP channel with message framing on top: length-prefixed frames in, a
/// queue of frames out written as the stream has room. Streams are scheduled on the
/// main run loop in the common modes, so a scroll in progress doesn't stall them.
private final class FramedChannel: NSObject, StreamDelegate {
    enum Kind: UInt8 {
        case heartbeat = 0
        case hello = 1
        case message = 2
        case file = 3
        /// Receiver → sender: a LaneOffer.
        case lane = 4
    }

    /// A queue snapshot is the largest thing sent; anything claiming to be bigger
    /// than this is a corrupt stream, not a message.
    private static let maxFrame = 8 << 20

    var onFrame: ((Kind, Data) -> Void)?
    var onClose: (() -> Void)?
    /// The outbox has just emptied. Posted, never called from inside send(), so a
    /// handler that sends again can't recurse.
    var onDrained: (() -> Void)?
    private(set) var lastInbound = Date()
    /// Bytes in the outbox not yet written.
    private(set) var queuedBytes = 0
    private(set) var lastOutbound = Date()
    /// Totals since the channel opened, for the periodic link report.
    private(set) var bytesRead = 0
    private(set) var bytesWritten = 0

    private let l2cap: CBL2CAPChannel
    var peerIdentifier: UUID { l2cap.peer.identifier }

    /// The far end showed it is alive some other way than on this channel.
    func heard() { lastInbound = Date() }

    private var inbox = Data()
    private var outbox: [Data] = []
    private var outOffset = 0
    private var closed = false
    private var readBuffer = [UInt8](repeating: 0, count: 16 * 1024)

    init(_ l2cap: CBL2CAPChannel) {
        self.l2cap = l2cap
        super.init()
        for stream in [l2cap.inputStream as Stream, l2cap.outputStream as Stream] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
    }

    func send(kind: Kind, body: Data, droppable: Bool) {
        guard !closed else { return }
        if droppable && !outbox.isEmpty { return }
        var frame = Data(capacity: 5 + body.count)
        withUnsafeBytes(of: UInt32(body.count + 1).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(body)
        outbox.append(frame)
        queuedBytes += frame.count
        lastOutbound = Date()
        pump()
    }

    func close() {
        guard !closed else { return }
        closed = true
        for stream in [l2cap.inputStream as Stream, l2cap.outputStream as Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        outbox = []
        queuedBytes = 0
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard !closed else { return }
        switch event {
        case .hasBytesAvailable: readAvailable()
        case .hasSpaceAvailable: pump()
        case .errorOccurred, .endEncountered:
            linkLog("channel stream " + (event == .endEncountered ? "ended" : "error: \(stream.streamError.map { "\($0)" } ?? "unknown")"))
            close()
            onClose?()
        default: break
        }
    }

    private func pump() {
        let output = l2cap.outputStream!
        let hadBacklog = !outbox.isEmpty
        defer {
            if hadBacklog, outbox.isEmpty, !closed {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.outbox.isEmpty else { return }
                    self.onDrained?()
                }
            }
        }
        while !closed, output.hasSpaceAvailable, let frame = outbox.first {
            let written = frame.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                return output.write(base + outOffset, maxLength: frame.count - outOffset)
            }
            if written < 0 {
                close()
                onClose?()
                return
            }
            if written == 0 { return }
            outOffset += written
            queuedBytes -= written
            bytesWritten += written
            if outOffset == frame.count {
                outbox.removeFirst()
                outOffset = 0
            }
        }
    }

    private func readAvailable() {
        let input = l2cap.inputStream!
        while input.hasBytesAvailable {
            let count = input.read(&readBuffer, maxLength: readBuffer.count)
            if count <= 0 { break }
            inbox.append(readBuffer, count: count)
            bytesRead += count
        }
        lastInbound = Date()
        while inbox.count >= 4 {
            let start = inbox.startIndex
            let length = inbox[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maxFrame else {
                linkLog("corrupt frame length \(length) — closing")
                close()
                onClose?()
                return
            }
            guard inbox.count >= 4 + length else { break }
            let kindByte = inbox[start + 4]
            let body = inbox.subdata(in: start + 5..<start + 4 + length)
            inbox.removeSubrange(start..<start + 4 + length)
            // Unknown kinds are skipped, so a later build can add one without
            // breaking this one.
            if let kind = Kind(rawValue: kindByte) { onFrame?(kind, body) }
            if closed { return }
        }
    }
}
