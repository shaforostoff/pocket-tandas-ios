// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RestorationDSPTests.swift
//  Pocket TandasTests
//
//  The host glue around the restoration cores, not the cores themselves: a
//  prepared but bypassed filter builds no cores yet still holds its delay, and
//  engaging it afterwards — the cores built off the audio thread and handed over
//  — gets audio flowing through them, the same as one engaged before prepare.
//

import XCTest
@testable import Pocket_Tandas

final class RestorationDSPTests: XCTestCase {

    private let rate: Double = 44100
    private let block = 512

    /// Run `blocks` blocks of `signal` (indexed by absolute frame) through
    /// `render`, stereo, and return what came out of channel 0.
    private func run(blocks: Int, from start: Int = 0,
                     signal: (Int) -> Float,
                     render: (UnsafePointer<UnsafeMutablePointer<Float>>, Int) -> Void) -> [Float] {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { left.deallocate(); right.deallocate(); pointers.deallocate() }
        pointers[0] = left
        pointers[1] = right

        var out: [Float] = []
        out.reserveCapacity(blocks * block)
        for b in 0..<blocks {
            for i in 0..<block {
                let v = signal(start + b * block + i)
                left[i] = v
                right[i] = v
            }
            render(UnsafePointer(pointers), block)
            out.append(contentsOf: UnsafeBufferPointer(start: left, count: block))
        }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))).squareRoot()
    }

    // MARK: - Declick

    func testBypassedDeclickHoldsItsDelayWithoutRunningTheCores() {
        let unit = PTDeclickProcessor()
        unit.bypassed = true
        XCTAssertTrue(unit.prepare(sampleRate: rate, channelCount: 2, maxFrames: block))
        let latency = unit.latencyFrames
        XCTAssertGreaterThan(latency, 0)

        let ramp: (Int) -> Float = { Float($0 % 1000) / 1000 }
        let out = run(blocks: 20, signal: ramp) { unit.render($0, channelCount: 2, frameCount: $1) }

        for i in latency..<out.count {
            XCTAssertEqual(out[i], ramp(i - latency), "frame \(i) is not the input \(latency) frames late")
        }
        XCTAssertEqual(unit.seenSamples, 0, "a bypassed declicker fed its cores")
    }

    func testDeclickEngagedAfterPrepareStartsRepairing() {
        let unit = PTDeclickProcessor()
        unit.bypassed = true
        XCTAssertTrue(unit.prepare(sampleRate: rate, channelCount: 2, maxFrames: block))
        let latency = unit.latencyFrames

        let noise: (Int) -> Float = { i in Float(sin(Double(i) * 0.37) * 0.1) }
        _ = run(blocks: 10, signal: noise) { unit.render($0, channelCount: 2, frameCount: $1) }
        XCTAssertEqual(unit.seenSamples, 0)

        unit.bypassed = false
        let out = run(blocks: 40, from: 10 * block, signal: noise) {
            unit.render($0, channelCount: 2, frameCount: $1)
        }
        XCTAssertGreaterThan(unit.seenSamples, 0, "the cores built on engaging never ran")
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
        XCTAssertEqual(unit.latencyFrames, latency, "latency moved on engaging")
    }

    func testDeclickEngagedBeforePrepareRunsFromTheFirstBlock() {
        let unit = PTDeclickProcessor()
        unit.bypassed = false
        XCTAssertTrue(unit.prepare(sampleRate: rate, channelCount: 2, maxFrames: block))
        _ = run(blocks: 4, signal: { _ in 0.01 }) { unit.render($0, channelCount: 2, frameCount: $1) }
        XCTAssertGreaterThan(unit.seenSamples, 0)
    }

    func testDeclickReengagesAfterAReprepare() {
        let unit = PTDeclickProcessor()
        unit.bypassed = true
        XCTAssertTrue(unit.prepare(sampleRate: rate, channelCount: 2, maxFrames: block))
        unit.bypassed = false
        // A route change re-prepares the unit: the cores go with the old format
        // and have to be built again for the new one.
        unit.unprepare()
        XCTAssertTrue(unit.prepare(sampleRate: 48000, channelCount: 2, maxFrames: block))
        _ = run(blocks: 4, signal: { _ in 0.01 }) { unit.render($0, channelCount: 2, frameCount: $1) }
        XCTAssertGreaterThan(unit.seenSamples, 0)
    }

    // MARK: - Dehum

    func testDehumEngagedAfterPrepareCancelsAPinnedLine() {
        let unit = PTDehumProcessor()
        var params = PTDehumParamsDefault()
        params.frequency = 50
        unit.setParams(params)
        unit.bypassed = true
        XCTAssertTrue(unit.prepare(sampleRate: rate, channelCount: 2, maxFrames: block))

        let hum: (Int) -> Float = { i in Float(0.5 * sin(2 * .pi * 50 * Double(i) / 44100)) }
        let dry = run(blocks: 20, signal: hum) { unit.render($0, channelCount: 2, frameCount: $1) }
        for i in 0..<dry.count { XCTAssertEqual(dry[i], hum(i), "bypassed dehum touched frame \(i)") }

        unit.bypassed = false
        // Ten seconds: long enough for any settling the pinned notch does.
        let blocks = Int(10 * rate) / block
        let wet = run(blocks: blocks, from: 20 * block, signal: hum) {
            unit.render($0, channelCount: 2, frameCount: $1)
        }
        let tail = wet.suffix(Int(rate))
        XCTAssertLessThan(rms(tail), 0.5 * rms(dry[...]), "the engaged notch did not take the hum out")
    }
}
