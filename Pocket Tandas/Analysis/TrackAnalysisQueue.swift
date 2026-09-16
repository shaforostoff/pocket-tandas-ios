// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackAnalysisQueue.swift
//  Pocket Tandas
//
//  Runs `TrackAnalyzer` over many tracks, several at a time, off the main thread.
//
//  Two levels of parallelism, and they pull in opposite directions. Each track is
//  analysed on ONE thread — the core is asked for exactly that, and its answer is
//  the same either way — because whole tracks running side by side is what makes
//  a folder finish faster: reading a track is a solid block of one core and dwarfs
//  the analysis that follows it. So the spread is across tracks, not inside one.
//
//  Its own OperationQueue rather than Swift Concurrency: `TrackAnalyzer.analyze`
//  blocks for seconds at a time, and blocking that many threads of the cooperative
//  pool would starve everything else the app awaits. `.utility` keeps it behind
//  playback and the UI, which have to stay smooth while it runs.
//

import Foundation

final class TrackAnalysisQueue {
    struct Job: Hashable {
        let key: String
        /// The file, or a Music-library asset URL. Whatever AVFoundation can read.
        let url: URL
    }

    /// Which submission a job belongs to, and therefore what can call it off.
    enum Batch {
        /// The folder on screen. Superseded — and cancelled — when the user moves
        /// to another one, the same way the tag scan is.
        case folder
        /// Tracks in the play queue. Nothing withdraws these: they were put there
        /// deliberately, and they are the ones about to be played.
        case standing
    }

    /// Tracks analysed side by side: every core but two. The two left over are for
    /// playback and the UI, which is the whole point of not taking them.
    static let concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

    /// Called on the main actor as each track lands. A track that failed to read,
    /// or was cancelled, reports nothing at all.
    private let onResult: @MainActor (String, TrackAnalysisResult) -> Void

    private let operations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.pockettandas.analysis"
        queue.maxConcurrentOperationCount = TrackAnalysisQueue.concurrency
        queue.qualityOfService = .utility
        return queue
    }()

    /// Guards both fields below; taken on the main actor when work is submitted
    /// and on an operation's own thread when it finishes.
    private let lock = NSLock()
    /// Keys already submitted and not yet finished, so a folder revisited while
    /// its first pass is still running doesn't queue everything twice.
    private var inFlight: Set<String> = []
    /// The `.folder` batch, for `cancelFolderWork`. Pruned as it is rebuilt.
    private var folderOperations: [AnalysisOperation] = []

    init(onResult: @escaping @MainActor (String, TrackAnalysisResult) -> Void) {
        self.onResult = onResult
    }

    /// Analyse `jobs`, skipping any track already in flight.
    @MainActor
    func submit(_ jobs: [Job], as batch: Batch) {
        guard !jobs.isEmpty else { return }

        lock.lock()
        let fresh = jobs.filter { inFlight.insert($0.key).inserted }
        let queued = fresh.map { AnalysisOperation(job: $0) }
        if batch == .folder {
            folderOperations.removeAll { $0.isFinished }
            folderOperations.append(contentsOf: queued)
        }
        lock.unlock()

        for operation in queued {
            operation.completionBlock = { [weak self, weak operation] in
                guard let self, let operation else { return }
                self.finished(operation)
            }
        }
        operations.addOperations(queued, waitUntilFinished: false)
    }

    /// Drop the folder batch — both what is waiting and what is running. An
    /// abandoned track is simply not recorded, so revisiting the folder starts it
    /// again rather than finding a half-measurement.
    @MainActor
    func cancelFolderWork() {
        lock.lock()
        let cancelling = folderOperations
        folderOperations.removeAll()
        // Released here rather than when each operation actually stops. A
        // cancelled operation reports finished on its own time, and the folder is
        // very often submitted again right away — navigate away and back — so
        // waiting would leave every one of its tracks looking like it was already
        // being measured, and skip the lot. The worst this costs is a moment with
        // the old operation winding down beside the new one; the old one is
        // cancelled, so it records nothing.
        for operation in cancelling { inFlight.remove(operation.job.key) }
        lock.unlock()
        for operation in cancelling { operation.cancel() }
    }

    /// Runs once per operation, on whatever thread finished it — including for one
    /// cancelled before it ever started, which is why the key is released here and
    /// not at the end of `main`.
    private func finished(_ operation: AnalysisOperation) {
        lock.lock()
        inFlight.remove(operation.job.key)
        lock.unlock()

        guard let result = operation.result else { return }
        let key = operation.job.key
        Task { @MainActor in self.onResult(key, result) }
    }
}

/// One track's read. `result` is written on the operation's own thread before it
/// reports finished and read by the completion block afterwards, which the
/// finished transition orders — hence the unchecked conformance.
private final class AnalysisOperation: Operation, @unchecked Sendable {
    let job: TrackAnalysisQueue.Job
    /// nil when the track could not be read, or the operation was cancelled.
    private(set) var result: TrackAnalysisResult?

    init(job: TrackAnalysisQueue.Job) {
        self.job = job
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        let outcome = TrackAnalyzer.analyze(url: job.url) { [weak self] in
            self?.isCancelled ?? true
        }
        if case .measured(let measured) = outcome { result = measured }
    }
}
