// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  WiFiLane.swift
//  Pocket Tandas
//
//  The fast lane for file transfers. Bluetooth carries the link itself — it is
//  what finds the other phone and what keeps a locked receiver awake — but it
//  moves a file at about 25 KB/s. Once the link is up the receiver also listens on
//  TCP, advertised over Bonjour with peer-to-peer Wi-Fi allowed, so the two phones
//  reach each other with or without a shared network. It tells the sender the
//  service name and a one-time token over the Bluetooth channel, which is already
//  the trusted one; a lane that doesn't open with that token is closed.
//
//  Only files travel here (see PeerLink's routing): each transfer keeps to the
//  lane it started on, so its start, pieces and end stay in order. When the lane
//  fails or stalls, a transfer it was carrying is sent again over Bluetooth.
//
//  Wire: the same frames as the L2CAP channel, [UInt32 BE length][UInt8 kind][body].
//

import Foundation
import Network

final class WiFiLane {
    /// Same values as the Bluetooth channel's kinds.
    enum Kind: UInt8 {
        case hello = 1     // the token, first thing on the lane
        case message = 2
        case file = 3
    }

    static let serviceType = "_ptandas._tcp"
    private static let maxFrame = 8 << 20

    var onReady: (() -> Void)?
    var onFrame: ((Kind, Data) -> Void)?
    /// Failed or closed by the other end — not called for close().
    var onClose: ((String) -> Void)?
    /// A send has been handed to the network stack.
    var onDrained: (() -> Void)?

    /// Bytes handed to send() that the stack hasn't taken yet.
    private(set) var queuedBytes = 0
    /// The last time a send completed or anything arrived — how a lane that has
    /// stalled with data waiting is spotted.
    private(set) var lastProgress = Date()
    private(set) var bytesWritten = 0
    private(set) var bytesRead = 0
    private(set) var isReady = false

    private let connection: NWConnection
    private var inbox = Data()
    private var closed = false

    static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// The sender's end, to the receiver's advertised service.
    convenience init(service name: String) {
        let endpoint = NWEndpoint.service(name: name, type: Self.serviceType, domain: "local.", interface: nil)
        self.init(NWConnection(to: endpoint, using: Self.parameters))
    }

    /// The receiver's end, from its listener.
    init(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.lastProgress = Date()
                self.onReady?()
            case .failed(let error):
                self.fail("failed: \(error)")
            case .cancelled:
                self.fail("cancelled")
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    var path: String {
        connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?"
    }

    func send(kind: Kind, body: Data) {
        guard !closed else { return }
        var frame = Data(capacity: 5 + body.count)
        withUnsafeBytes(of: UInt32(body.count + 1).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(body)
        let count = frame.count
        queuedBytes += count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error { return self.fail("send: \(error)") }
            self.queuedBytes -= count
            self.bytesWritten += count
            self.lastProgress = Date()
            self.onDrained?()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        queuedBytes = 0
        connection.cancel()
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        close()
        onClose?(reason)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.bytesRead += data.count
                self.lastProgress = Date()
                self.inbox.append(data)
                self.parse()
                if self.closed { return }
            }
            if let error { return self.fail("receive: \(error)") }
            if isComplete { return self.fail("closed by the other end") }
            self.receive()
        }
    }

    private func parse() {
        while inbox.count >= 4 {
            let start = inbox.startIndex
            let length = inbox[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maxFrame else { return fail("corrupt frame length \(length)") }
            guard inbox.count >= 4 + length else { break }
            let kindByte = inbox[start + 4]
            let body = inbox.subdata(in: start + 5..<start + 4 + length)
            inbox.removeSubrange(start..<start + 4 + length)
            if let kind = Kind(rawValue: kindByte) { onFrame?(kind, body) }
            if closed { return }
        }
    }
}

/// The receiver's listening end: one Bonjour service per Bluetooth link.
final class WiFiLaneListener {
    /// The Bonjour service name — random, so it says nothing about the phone.
    let name = "PT-" + UUID().uuidString.prefix(8)

    var onReady: (() -> Void)?
    var onConnection: ((NWConnection) -> Void)?
    var onFailed: ((String) -> Void)?

    private let listener: NWListener

    init() throws {
        listener = try NWListener(using: WiFiLane.parameters)
        listener.service = NWListener.Service(name: name, type: WiFiLane.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onFailed?("\(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.onConnection?(connection) }
        listener.start(queue: .main)
    }

    func cancel() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }
}
