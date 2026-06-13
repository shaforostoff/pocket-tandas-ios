// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  FadeController.swift
//  Pocket Tandas
//
//  A cancellable linear volume ramp driven by a main-run-loop timer (in
//  `.common` mode so it keeps stepping while the user scrolls). `completion`
//  runs only when the ramp finishes naturally; `cancel()` stops it WITHOUT
//  calling completion — that's what lets Resume abort the scheduled stop
//  atomically (everything runs on the main thread, so there's no race).
//

import Foundation

final class FadeController {
    private var timer: Timer?
    private(set) var isRunning = false

    func ramp(from: Float,
              to: Float,
              duration: TimeInterval,
              steps: Int = 60,
              apply: @escaping (Float) -> Void,
              completion: @escaping () -> Void) {
        cancel()
        guard duration > 0, steps > 0 else {
            apply(to)
            completion()
            return
        }

        isRunning = true
        apply(from)
        let interval = duration / Double(steps)
        var step = 0

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            step += 1
            let progress = Float(step) / Float(steps)
            apply(from + (to - from) * progress)
            if step >= steps {
                t.invalidate()
                self?.timer = nil
                self?.isRunning = false
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }
}
