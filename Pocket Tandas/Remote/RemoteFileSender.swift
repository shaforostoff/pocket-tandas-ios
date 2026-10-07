// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteFileSender.swift
//  Pocket Tandas
//
//  Remote Send's half of moving tracks between the phones. When the receiver
//  reports adds it couldn't find, the ones that are files on this phone are offered
//  to the DJ for sending across; on yes they go one at a time, each saved on the
//  receiver under the same base-relative path it has here and queued there as
//  it lands.
//
//  Anything above 128 kbps can go as a 128 kbps AAC copy instead (see
//  AACTranscoder), tags included. Bluetooth is slow — tens to a couple of hundred
//  kilobytes a second — so for a FLAC that is the difference between half a minute
//  and several. The copy is made just before its turn, into a temporary file that
//  is deleted once sent, and the next one is encoded while this one is on the air.
//
//  Pacing: a file goes in 16 KB pieces, the next one queued only when the link's
//  outbox has drained (PeerLink.onOutboundDrained). So a Stop tapped mid-transfer
//  waits behind at most one piece rather than behind the rest of the file.
//
//  Plain @Observable, not @MainActor (see observable-not-mainactor); touched on
//  main only, like the link that drives it.
//

import Foundation
import AVFoundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Wire

/// The receiver's answer to a batch of adds whose requests all carried a ref.
struct AddTracksOutcome: Codable, Hashable {
    var resolved: Int
    /// Refs of the requests it found no track for.
    var missing: [Int]
    /// It has a base folder to save files into.
    var acceptsFiles: Bool
}

/// Announces a file; its bytes follow as PeerLink file frames under the same id,
/// then `.fileEnd`. `relativePath` is where it goes under the receiver's base
/// folder — the sender's own path, with an .m4a extension for a compressed copy.
struct FileTransferStart: Codable, Hashable {
    var id: Int
    var relativePath: String
    var size: Int64
}

struct FileTransferResult: Codable, Hashable {
    var id: Int
    var saved: Bool
    var reason: String?
}

// MARK: - Sender

@Observable
final class RemoteFileSender {

    /// A missing track that exists as a file here.
    struct Candidate: Hashable {
        let url: URL
        let relativePath: String
        let title: String
        var size: Int64 = 0
        var duration: TimeInterval = 0

        /// Rough: the whole file over its length, so embedded cover art counts too.
        var bitRate: Double { duration > 0 ? Double(size) * 8 / duration : 0 }

        /// Worth a compressed copy. The margin is for that cover art: a 128 kbps
        /// MP3 carrying a few hundred KB of it measures a little over 128, and
        /// re-encoding it would only cost quality.
        var isCompressible: Bool {
            bitRate > Double(AACTranscoder.bitRate) * 1.15 && AACTranscoder.canDecode(url)
        }

        /// What it weighs as sent.
        func sendSize(compressed: Bool) -> Int64 {
            guard compressed, isCompressible else { return size }
            return Int64(duration * Double(AACTranscoder.bitRate) / 8)
        }
    }

    struct Offer: Identifiable {
        let id = UUID()
        let candidates: [Candidate]

        var compressibleCount: Int { candidates.filter(\.isCompressible).count }
        func totalSize(compressed: Bool) -> Int64 {
            candidates.reduce(0) { $0 + $1.sendSize(compressed: compressed) }
        }
    }

    struct Progress: Equatable {
        var index: Int          // 1-based, of `count`
        var count: Int
        var title: String
        var sent: Int64
        var size: Int64
        /// Making the compressed copy; nothing is on the air yet.
        var encoding: Bool

        var fraction: Double { size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
    }

    /// Waiting on the DJ's answer.
    private(set) var offer: Offer?
    /// The file on the air, while a transfer runs.
    private(set) var progress: Progress?
    /// How the last transfer ended, briefly.
    private(set) var notice: String?

    @ObservationIgnored private let link: PeerLink

    private struct Job {
        let candidate: Candidate
        let compress: Bool
    }

    private struct Prepared {
        let url: URL
        let relativePath: String
        let isTemporary: Bool
    }

    private struct Current {
        let id: Int
        let handle: FileHandle
        let prepared: Prepared
        let size: Int64
        var sent: Int64 = 0
    }

    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var next = 0
    @ObservationIgnored private var preparing: [Int: Task<Prepared, Error>] = [:]
    @ObservationIgnored private var current: Current?
    @ObservationIgnored private var nextID = 1
    /// Bumped on cancel, so a preparation finishing afterwards knows it is stale.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saved = 0
    @ObservationIgnored private var failures: [String] = []
    /// Results still to come, by transfer id → title.
    @ObservationIgnored private var awaiting: [Int: String] = [:]
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private static let chunkSize = 16 * 1024
    /// Queue another piece while less than this is waiting to be written.
    private static let lowWater = 2 * chunkSize
    private static let temporaryFolder = FileManager.default.temporaryDirectory
        .appending(path: "RemoteSend", directoryHint: .isDirectory)

    init(link: PeerLink) {
        self.link = link
        link.onOutboundDrained = { [weak self] in self?.pump() }
        // Copies left behind by a run that was killed mid-transfer.
        try? FileManager.default.removeItem(at: Self.temporaryFolder)
    }

    var isBusy: Bool { progress != nil }

    // MARK: - Offer

    /// The receiver couldn't find these. Weigh them (off main: it opens every
    /// file), then put the question to the DJ.
    func propose(_ found: [Candidate]) {
        guard !found.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            var weighed: [Candidate] = []
            for var candidate in found {
                let values = try? candidate.url.resourceValues(forKeys: [.fileSizeKey])
                candidate.size = Int64(values?.fileSize ?? 0)
                let duration = try? await AVURLAsset(url: candidate.url).load(.duration)
                candidate.duration = duration.map(CMTimeGetSeconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
                weighed.append(candidate)
            }
            let ready = weighed.filter { $0.size > 0 }
            await MainActor.run { [weak self] in
                guard let self, !ready.isEmpty else { return }
                // A second batch while the first is still being asked about joins it.
                let earlier = self.offer?.candidates ?? []
                let merged = earlier + ready.filter { new in !earlier.contains { $0.url == new.url } }
                self.offer = Offer(candidates: merged)
            }
        }
    }

    func accept(compressed: Bool) {
        guard let offer else { return }
        self.offer = nil
        let wasIdle = jobs.count == next && current == nil && preparing.isEmpty
        jobs += offer.candidates.map { Job(candidate: $0, compress: compressed && $0.isCompressible) }
        if wasIdle {
            beginBackgroundTime()
            startNext()
        } else if let progress {
            self.progress?.count = progress.count + offer.candidates.count
        }
    }

    func decline() {
        offer = nil
    }

    // MARK: - Running

    /// Stop everything: the file on the air, and the ones waiting behind it.
    func cancel() {
        if let current {
            link.send(.fileCancel(id: current.id))
            awaiting[current.id] = nil
        }
        stopAll()
        finish(note: "Sending stopped.")
    }

    /// The link went down; nothing sent from here will arrive.
    func linkDropped() {
        offer = nil
        guard isBusy || !awaiting.isEmpty else { return }
        stopAll()
        awaiting = [:]
        finish(note: "Sending stopped — the connection dropped.")
    }

    func handle(_ result: FileTransferResult) {
        guard let title = awaiting.removeValue(forKey: result.id) else { return }
        if result.saved {
            saved += 1
        } else {
            failures.append(result.reason.map { "\(title): \($0)" } ?? title)
            // Refused up front (no room, a path it won't write): stop feeding it.
            if current?.id == result.id { abandonCurrent() }
        }
        if !isBusy && awaiting.isEmpty { finish(note: nil) }
    }

    private func startNext() {
        guard current == nil else { return }
        guard next < jobs.count else {
            progress = nil
            if awaiting.isEmpty { finish(note: nil) }
            return
        }
        let index = next
        let job = jobs[index]
        progress = Progress(index: index + 1, count: jobs.count, title: job.candidate.title,
                            sent: 0, size: job.candidate.sendSize(compressed: job.compress),
                            encoding: job.compress)
        let generation = generation
        let task = preparation(for: index)
        // The following one encodes while this one is on the air.
        if index + 1 < jobs.count { _ = preparation(for: index + 1) }
        Task { @MainActor [weak self] in
            let prepared: Prepared
            do {
                prepared = try await task.value
            } catch {
                guard let self, self.generation == generation else { return }
                self.preparing[index] = nil
                self.failures.append(job.candidate.title)
                self.next += 1
                self.startNext()
                return
            }
            guard let self, self.generation == generation else {
                if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) }
                return
            }
            self.preparing[index] = nil
            self.next += 1
            self.begin(prepared, title: job.candidate.title)
        }
    }

    private func preparation(for index: Int) -> Task<Prepared, Error> {
        if let existing = preparing[index] { return existing }
        let job = jobs[index]
        let task = Task.detached(priority: .userInitiated) { () throws -> Prepared in
            let candidate = job.candidate
            guard job.compress else {
                return Prepared(url: candidate.url, relativePath: candidate.relativePath, isTemporary: false)
            }
            try FileManager.default.createDirectory(at: Self.temporaryFolder, withIntermediateDirectories: true)
            let copy = Self.temporaryFolder.appending(path: UUID().uuidString + ".m4a")
            do {
                try await AACTranscoder.transcode(candidate.url, to: copy)
            } catch {
                // Better the original, slowly, than nothing.
                ptLog("[RemoteFileSender] couldn't compress \(candidate.url.lastPathComponent): \(error) — sending as is")
                return Prepared(url: candidate.url, relativePath: candidate.relativePath, isTemporary: false)
            }
            let path = (candidate.relativePath as NSString).deletingPathExtension + ".m4a"
            return Prepared(url: copy, relativePath: path, isTemporary: true)
        }
        preparing[index] = task
        return task
    }

    private func begin(_ prepared: Prepared, title: String) {
        guard let handle = try? FileHandle(forReadingFrom: prepared.url),
              let size = try? prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            failures.append(title)
            discard(prepared)
            return startNext()
        }
        let id = nextID
        nextID += 1
        current = Current(id: id, handle: handle, prepared: prepared, size: Int64(size))
        awaiting[id] = title
        progress?.encoding = false
        progress?.size = Int64(size)
        link.send(.fileStart(FileTransferStart(id: id, relativePath: prepared.relativePath, size: Int64(size))))
        pump()
    }

    /// Queue pieces of the current file until the link has enough waiting; called
    /// again each time it drains.
    private func pump() {
        while var file = current, link.outboundBacklog < Self.lowWater {
            let piece: Data
            do {
                piece = try file.handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                ptLog("[RemoteFileSender] read failed: \(error)")
                link.send(.fileCancel(id: file.id))
                awaiting[file.id] = nil
                failures.append(progress?.title ?? file.prepared.relativePath)
                abandonCurrent()
                return
            }
            if piece.isEmpty {
                link.send(.fileEnd(id: file.id))
                try? file.handle.close()
                discard(file.prepared)
                current = nil
                startNext()
                return
            }
            guard link.sendFileChunk(transfer: file.id, bytes: piece) else { return }
            file.sent += Int64(piece.count)
            current = file
            progress?.sent = file.sent
        }
    }

    private func abandonCurrent() {
        guard let file = current else { return }
        try? file.handle.close()
        discard(file.prepared)
        current = nil
        startNext()
    }

    private func stopAll() {
        generation += 1
        if let file = current {
            try? file.handle.close()
            discard(file.prepared)
        }
        current = nil
        preparing.values.forEach { $0.cancel() }
        preparing = [:]
        jobs = []
        next = 0
        progress = nil
    }

    private func discard(_ prepared: Prepared) {
        if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) }
    }

    private func finish(note: String?) {
        jobs = []
        next = 0
        progress = nil
        endBackgroundTime()
        let text: String
        if let note {
            text = saved > 0 ? "\(note) \(Self.tracks(saved)) arrived." : note
        } else if failures.isEmpty {
            guard saved > 0 else { return }
            text = "Sent \(Self.tracks(saved))."
        } else {
            text = "Sent \(saved), \(failures.count) failed: \(failures.prefix(3).joined(separator: "; "))"
        }
        saved = 0
        failures = []
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    private static func tracks(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    // MARK: - Background time

    /// A locked phone suspends the app within seconds, and with it the transfer.
    /// Ask for the few minutes iOS grants a task that is finishing up.
    private func beginBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remote file transfer") { [weak self] in
            self?.endBackgroundTime()
        }
        #endif
    }

    private func endBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }
}
