// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteFileReceiver.swift
//  Pocket Tandas
//
//  Remote Receive's half of a file transfer (see RemoteFileSender): saves each
//  incoming track under the base folder at the path the sender gave — the same
//  subfolders it sits in on the sending phone — and hands it on to be queued.
//
//  A file is written to a temporary file first and moved into the music folder
//  only once every byte has arrived, so an interrupted transfer never leaves half
//  a track in the library. The writes happen on a queue of their own: this is the
//  phone that is playing, and its track transitions are driven from main.
//
//  The path comes from the other phone, so it is held to the base folder: no
//  "..", no hidden components, and an audio extension — nothing else gets written.
//

import Foundation
import Observation

@Observable
final class RemoteFileReceiver {
    struct Progress: Equatable {
        var name: String
        var received: Int64
        var size: Int64
        var fraction: Double { size > 0 ? min(1, Double(received) / Double(size)) : 0 }
    }

    /// The file arriving now, for the receiver's banner.
    private(set) var progress: Progress?

    /// Called on main with each file saved into the library.
    @ObservationIgnored var onSaved: ((URL) -> Void)?

    @ObservationIgnored private let link: PeerLink
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let io = DispatchQueue(label: "RemoteFileReceiver.io", qos: .utility)

    private final class Incoming {
        let id: Int
        let destination: URL
        let temporary: URL
        let size: Int64
        var received: Int64 = 0
        /// Written to and closed on `io` only.
        var handle: FileHandle?
        /// Set on `io` when a write fails; read there at the end.
        var writeError: Error?

        init(id: Int, destination: URL, temporary: URL, size: Int64) {
            self.id = id
            self.destination = destination
            self.temporary = temporary
            self.size = size
        }
    }

    @ObservationIgnored private var incoming: [Int: Incoming] = [:]

    /// A track is a few MB, a long lossless one a few hundred; anything claiming
    /// more is not a track.
    private static let maxSize: Int64 = 1 << 30
    private static let temporaryFolder = FileManager.default.temporaryDirectory
        .appending(path: "RemoteReceive", directoryHint: .isDirectory)

    init(link: PeerLink, library: LibraryStore) {
        self.link = link
        self.library = library
        try? FileManager.default.removeItem(at: Self.temporaryFolder)
    }

    // MARK: - From the link (main)

    func start(_ start: FileTransferStart) {
        guard let base = library.baseURL else {
            return refuse(start.id, "this phone has no music folder chosen")
        }
        guard let destination = Self.destination(for: start.relativePath, under: base) else {
            return refuse(start.id, "not a track path this phone will write")
        }
        guard start.size > 0, start.size <= Self.maxSize else {
            return refuse(start.id, "unexpected size")
        }
        if let free = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < start.size + (50 << 20) {
            return refuse(start.id, "not enough free space")
        }
        let temporary = Self.temporaryFolder.appending(path: "\(start.id)-\(UUID().uuidString).part")
        let file = Incoming(id: start.id, destination: destination, temporary: temporary, size: start.size)
        incoming[start.id] = file
        progress = Progress(name: destination.lastPathComponent, received: 0, size: start.size)
        io.async {
            do {
                try FileManager.default.createDirectory(at: Self.temporaryFolder, withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                file.handle = try FileHandle(forWritingTo: temporary)
            } catch {
                file.writeError = error
            }
        }
    }

    func chunk(_ id: Int, _ bytes: Data) {
        guard let file = incoming[id] else { return }   // refused, cancelled, or unknown
        file.received += Int64(bytes.count)
        guard file.received <= file.size else {
            discard(file)
            return refuse(id, "more data than announced")
        }
        if progress?.name == file.destination.lastPathComponent { progress?.received = file.received }
        io.async {
            guard file.writeError == nil, let handle = file.handle else { return }
            do { try handle.write(contentsOf: bytes) } catch { file.writeError = error }
        }
    }

    func end(_ id: Int) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        if incoming.isEmpty { progress = nil }
        let complete = file.received == file.size
        io.async { [weak self] in
            try? file.handle?.close()
            file.handle = nil
            var result: Result<URL, Error>
            if let error = file.writeError {
                result = .failure(error)
            } else if !complete {
                result = .failure(CocoaError(.fileReadCorruptFile))
            } else {
                result = Result { try Self.moveIntoPlace(file.temporary, file.destination) }
            }
            if case .failure = result { try? FileManager.default.removeItem(at: file.temporary) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    ptLog("[RemoteFileReceiver] saved \(url.lastPathComponent)")
                    self.onSaved?(url)
                    self.link.send(.fileResult(FileTransferResult(id: id, saved: true)))
                case .failure(let error):
                    ptLog("[RemoteFileReceiver] couldn't save \(file.destination.lastPathComponent): \(error)")
                    self.link.send(.fileResult(FileTransferResult(id: id, saved: false,
                                                                  reason: complete ? "couldn’t be saved" : "arrived incomplete")))
                }
            }
        }
    }

    func cancel(_ id: Int) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        if incoming.isEmpty { progress = nil }
        discard(file)
    }

    /// The link went down: whatever was arriving never will.
    func abortAll() {
        incoming.values.forEach(discard)
        incoming = [:]
        progress = nil
    }

    // MARK: - Helpers

    private func refuse(_ id: Int, _ reason: String) {
        ptLog("[RemoteFileReceiver] refusing transfer \(id): \(reason)")
        incoming[id] = nil
        if incoming.isEmpty { progress = nil }
        link.send(.fileResult(FileTransferResult(id: id, saved: false, reason: reason)))
    }

    private func discard(_ file: Incoming) {
        io.async {
            try? file.handle?.close()
            file.handle = nil
            try? FileManager.default.removeItem(at: file.temporary)
        }
    }

    /// `relativePath` under `base`, or nil if it would land anywhere else or isn't
    /// an audio file.
    ///
    /// Staying inside `base` follows from the components alone — no "..", nothing
    /// hidden, a leading "/" just an empty component — so there is no path-prefix
    /// check to get wrong. (One on standardized paths refused everything: Foundation
    /// strips /private from a path that exists, like the base folder, and not from
    /// one that doesn't yet, like the file about to be written.)
    static func destination(for relativePath: String, under base: URL) -> URL? {
        let parts = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard let name = parts.last,
              parts.allSatisfy({ $0 != ".." && !$0.hasPrefix(".") }) else { return nil }
        var url = base
        for folder in parts.dropLast() { url.append(path: folder, directoryHint: .isDirectory) }
        url.append(path: name, directoryHint: .notDirectory)
        return AudioFileTypes.isAudio(url) ? url : nil
    }

    /// Into the library, creating its folders. A name already taken (the resolver
    /// looked for this track and missed, so it is something else) gets a number.
    private static func moveIntoPlace(_ temporary: URL, _ destination: URL) throws -> URL {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = destination
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var number = 2
        while manager.fileExists(atPath: target.path) {
            target = folder.appending(path: "\(stem) \(number).\(ext)", directoryHint: .notDirectory)
            number += 1
        }
        try manager.moveItem(at: temporary, to: target)
        return target
    }
}
