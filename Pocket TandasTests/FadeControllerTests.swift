// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  FadeControllerTests.swift
//  Pocket TandasTests
//
//  The fade ramp reaches its target and calls completion; cancelling prevents
//  completion (this is what lets Resume abort the scheduled stop).
//

import XCTest
@testable import Pocket_Tandas

final class FadeControllerTests: XCTestCase {

    func testRampReachesTargetAndCompletes() {
        let fade = FadeController()
        let done = expectation(description: "completion called")
        var lastValue: Float = -1

        fade.ramp(from: 1.0, to: 0.0, duration: 0.2, steps: 4,
                  apply: { lastValue = $0 },
                  completion: { done.fulfill() })

        wait(for: [done], timeout: 2.0)
        XCTAssertEqual(lastValue, 0.0, accuracy: 0.0001)
        XCTAssertFalse(fade.isRunning)
    }

    func testCancelPreventsCompletion() {
        let fade = FadeController()
        let notCalled = expectation(description: "completion must NOT be called")
        notCalled.isInverted = true

        fade.ramp(from: 1.0, to: 0.0, duration: 1.0, steps: 20,
                  apply: { _ in },
                  completion: { notCalled.fulfill() })
        fade.cancel()

        wait(for: [notCalled], timeout: 0.6)
        XCTAssertFalse(fade.isRunning)
    }
}
