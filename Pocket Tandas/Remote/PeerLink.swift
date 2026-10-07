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
//  receiver counts the link as up only once it arrives.
//
//  Wire: each frame is [UInt32 big-endian length][UInt8 kind][body]. Kinds are a
//  heartbeat (empty), hello (identity JSON), message (a RemoteMessage encoding) and
//  file (a piece of a track being sent across: [UInt32 BE transfer id][bytes] —
//  raw, since base64 in JSON would add a third to the slowest thing on the link).
//  The receiver sends a heartbeat when it has been quiet for a few seconds and the
//  sender answers each one, so both ends notice a dead link within seconds — the
//  stream alone can sit open on a peer that has gone out of range.
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

    // MARK: GATT layout

    static let serviceUUID = CBUUID(string: "80CFC7CE-36B1-497E-9DD5-AC90F09BD31B")
    static let identityUUID = CBUUID(string: "9180F492-E7DF-45A0-B422-2BB8E20A4F93")
    /// Apple's conventional UUID for "the PSM of this service's L2CAP channel".
    static let psmUUID = CBUUID(string: CBUUIDL2CAPPSMCharacteristicString)

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
    @ObservationIgnored private static let tickInterval: TimeInterval = 1

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
        /// Probed and found not to be the remembered receiver, or unreadable — don't
        /// keep connecting to it.
        var probeSettled = false
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
        var identity: Identity?
        var psm: CBL2CAPPSM?
    }

    private struct PreferredReceiver: Codable {
        let identity: Identity
        var peripheralID: UUID
    }

    @ObservationIgnored private static let installIDKey = "PeerLink.installID"
    @ObservationIgnored private static let preferredKey = "PeerLink.preferredReceiver"

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
        guard role == .sender, let entry = known[peer.id] else { return }
        let peripheral = entry.peripheral
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
        forgetPreferred()
        send(.goodbye)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.channelLost()
        }
    }

    /// Leaving the screen. Keeps the remembered receiver, so coming back reconnects.
    func stop() {
        isActive = false
        tick?.invalidate()
        tick = nil
        channel?.close()
        channel = nil
        channelPeer = nil
        unintroduced.forEach { $0.channel.close() }
        unintroduced = []
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
    var outboundBacklog: Int { channel?.queuedBytes ?? 0 }

    /// One piece of a file transfer. False when there is no link to send it on.
    @discardableResult
    func sendFileChunk(transfer id: Int, bytes: Data) -> Bool {
        guard let channel else { return false }
        var body = Data(capacity: 4 + bytes.count)
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: id).bigEndian) { body.append(contentsOf: $0) }
        body.append(bytes)
        channel.send(kind: .file, body: body, droppable: false)
        return true
    }

    func send(_ message: RemoteMessage) {
        guard let channel, let data = message.encoded() else { return }
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
            if now.timeIntervalSince(channel.lastInbound) > Self.silenceLimit {
                ptLog("[PeerLink] nothing heard for \(Int(Self.silenceLimit))s — link is dead")
                channelLost()
            } else if role == .receiver, now.timeIntervalSince(channel.lastOutbound) >= Self.heartbeatInterval {
                channel.send(kind: .heartbeat, body: Data(), droppable: true)
            }
        }
        switch role {
        case .receiver:
            let expired = unintroduced.filter { now.timeIntervalSince($0.openedAt) > Self.attemptLimit }
            if !expired.isEmpty {
                expired.forEach { $0.channel.close() }
                unintroduced.removeAll { entry in expired.contains { $0.channel === entry.channel } }
            }
        case .sender:
            // The contact outlives its attempt — it stays set for as long as the
            // channel it produced is up — so only an attempt still without a channel
            // can time out.
            if channel == nil, let contact, now.timeIntervalSince(contact.startedAt) > Self.attemptLimit {
                ptLog("[PeerLink] connection attempt to \(displayName(for: contact.peripheral.identifier)) timed out")
                contactFailed()
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
                ptLog("[PeerLink] channel closed")
                self.channelLost()
            } else {
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
            guard role == .receiver, let peer = try? JSONDecoder().decode(Identity.self, from: body) else { return }
            introduce(framed, as: peer)
        case .message:
            guard framed === channel else { return }
            decodeQueue.async { [weak self] in
                guard let message = RemoteMessage.decode(body) else { return }
                DispatchQueue.main.async {
                    guard let self, framed === self.channel else { return }
                    // The peer is leaving deliberately — don't chase it.
                    if case .goodbye = message { self.forgetPreferred() }
                    self.onReceive?(message)
                }
            }
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
        lost.close()
        channel = nil
        channelPeer = nil
        setState(isActive ? .disconnected : .idle)
        onDisconnected?()
        guard role == .sender else { return }
        // Tear down the GATT link too, so the reconnect starts from a clean connect;
        // didDisconnect then re-arms the standing reconnect if we still want it.
        if let contact, contact.peripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(contact.peripheral)
        } else {
            self.contact = nil
            beginSearch()
        }
    }

    private func setState(_ newState: ConnectionState) {
        if connectionState != newState { connectionState = newState }
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
            channelLost()
            if isActive, let reason = Self.unavailableReason(peripheral.state) { setState(.unavailable(reason)) }
        }
    }

    private func publish() {
        guard let manager = peripheralManager, manager.state == .poweredOn else { return }
        if !serviceAdded && publishedPSM == nil && !publishInFlight {
            publishInFlight = true
            manager.removeAllServices()
            let identityChar = CBMutableCharacteristic(type: Self.identityUUID, properties: [.read],
                                                       value: nil, permissions: [.readable])
            let psmChar = CBMutableCharacteristic(type: Self.psmUUID, properties: [.read],
                                                  value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [identityChar, psmChar]
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
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                  CBAdvertisementDataLocalNameKey: identity.name])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            ptLog("[PeerLink] adding the service failed: \(error)")
            publishInFlight = false   // the next startAdvertising() tries again
            return
        }
        serviceAdded = true
        publishInFlight = publishedPSM == nil
        startAdvertisingIfReady()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            ptLog("[PeerLink] publishing the channel failed: \(error)")
            publishInFlight = false   // the next startAdvertising() tries again
            return
        }
        publishedPSM = PSM
        publishInFlight = !serviceAdded
        startAdvertisingIfReady()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { ptLog("[PeerLink] advertise error: \(error)") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value: Data?
        switch request.characteristic.uuid {
        case Self.identityUUID: value = try? JSONEncoder().encode(identity)
        case Self.psmUUID:      value = publishedPSM.map { withUnsafeBytes(of: $0.littleEndian) { Data($0) } }
        default:                value = nil
        }
        guard let value else { return peripheral.respond(to: request, withResult: .attributeNotFound) }
        guard request.offset <= value.count else { return peripheral.respond(to: request, withResult: .invalidOffset) }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel else {
            if let error { ptLog("[PeerLink] incoming channel failed: \(error)") }
            return
        }
        guard isActive else { return }
        unintroduced.append((makeFramed(channel), Date()))
    }

    /// A sender said hello. Stay 1:1: a second phone is turned away while the
    /// current link is alive — but not when the current one has gone quiet, or when
    /// the hello is from that same phone, which then is just coming back from a link
    /// that died without us noticing yet.
    private func introduce(_ framed: FramedChannel, as peer: Identity) {
        unintroduced.removeAll { $0.channel === framed }
        if let current = channel {
            let sameSender = channelPeer.map { $0.id == peer.id } ?? false
            let quiet = Date().timeIntervalSince(current.lastInbound) > Self.heartbeatInterval * 2
            guard sameSender || quiet else {
                ptLog("[PeerLink] turning away \(peer.name) — already connected")
                framed.close()
                return
            }
            ptLog("[PeerLink] \(peer.name) replaces the current link")
            current.close()
        }
        let connected = Peer(id: peer.id, displayName: peer.name)
        channel = framed
        channelPeer = connected
        setState(.connected(peer.name))
        onConnected?(connected)
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
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        armStandingReconnect()
        probeNext()
    }

    private func armStandingReconnect() {
        guard let preferred = preferredReceiver, let central = centralManager,
              contact == nil, standingReconnect == nil,
              let peripheral = central.retrievePeripherals(withIdentifiers: [preferred.peripheralID]).first
        else { return }
        remember(peripheral, seen: false)
        standingReconnect = peripheral
        // No timeout: this completes whenever the receiver is next reachable.
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isActive else { return }
        remember(peripheral, advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        refreshDiscoveredPeers(now: Date())
        guard channel == nil else { return }
        // The remembered receiver, under a peripheral id we already recognise.
        if let preferred = preferredReceiver,
           known[peripheral.identifier]?.identity?.id == preferred.identity.id,
           contact?.peripheral !== peripheral {
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
            .filter { !$0.probeSettled && $0.identity == nil
                && now.timeIntervalSince($0.lastSeen) < Self.peerStaleAfter
                && ($0.advertisedName == nil || preferredReceiver != nil) }
            .min { $0.firstSeen < $1.firstSeen }
        guard let candidate else { return }
        beginContact(candidate.peripheral, intent: .probe)
    }

    private func beginContact(_ peripheral: CBPeripheral, intent: Contact.Intent) {
        contact = Contact(peripheral: peripheral, intent: intent, startedAt: Date())
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
        known[failed.peripheral.identifier]?.probeSettled = true
        dropContact()
        if failed.intent != .probe {
            if channel == nil { setState(.disconnected) }
            onDisconnected?()
        }
        beginSearch()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if current.intent != .probe { setState(.connecting(displayName(for: peripheral.identifier))) }
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        ptLog("[PeerLink] connect failed: \(error.map { "\($0)" } ?? "no reason")")
        if peripheral === standingReconnect { standingReconnect = nil }
        if contact?.peripheral === peripheral { contactFailed() } else { beginSearch() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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
            ptLog("[PeerLink] \(peripheral.identifier) has no remote service: \(error.map { "\($0)" } ?? "")")
            return contactFailed()
        }
        peripheral.discoverCharacteristics([Self.identityUUID, Self.psmUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard var current = contact, current.peripheral === peripheral else { return }
        let chars = service.characteristics ?? []
        current.identityCharacteristic = chars.first { $0.uuid == Self.identityUUID }
        current.psmCharacteristic = chars.first { $0.uuid == Self.psmUUID }
        contact = current
        guard let identityChar = current.identityCharacteristic, let psmChar = current.psmCharacteristic else {
            return contactFailed()
        }
        peripheral.readValue(for: identityChar)
        // A join doesn't need to wait for the identity to know it wants the PSM.
        if current.intent == .join { peripheral.readValue(for: psmChar) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard var current = contact, current.peripheral === peripheral else { return }
        guard error == nil, let value = characteristic.value else {
            ptLog("[PeerLink] reading \(characteristic.uuid) failed: \(error.map { "\($0)" } ?? "empty")")
            return contactFailed()
        }
        switch characteristic.uuid {
        case Self.identityUUID:
            guard let peer = try? JSONDecoder().decode(Identity.self, from: value) else { return contactFailed() }
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
            guard value.count >= 2 else { return contactFailed() }
            current.psm = CBL2CAPPSM(value[value.startIndex]) | CBL2CAPPSM(value[value.startIndex + 1]) << 8
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
        current.peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen l2cap: CBL2CAPChannel?, error: Error?) {
        guard let current = contact, current.peripheral === peripheral, let receiver = current.identity else { return }
        guard let l2cap else {
            ptLog("[PeerLink] opening the channel failed: \(error.map { "\($0)" } ?? "no reason")")
            return contactFailed()
        }
        let framed = makeFramed(l2cap)
        guard let hello = try? JSONEncoder().encode(identity) else { return contactFailed() }
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
        ptLog("[PeerLink] connected to \(receiver.name) in \(String(format: "%.2f", Date().timeIntervalSince(current.startedAt)))s")
        setState(.connected(receiver.name))
        onConnected?(connected)
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

    private let l2cap: CBL2CAPChannel
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
        }
        lastInbound = Date()
        while inbox.count >= 4 {
            let start = inbox.startIndex
            let length = inbox[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maxFrame else {
                ptLog("[PeerLink] corrupt frame length \(length) — closing")
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
