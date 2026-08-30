// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  FadeController.swift
//  Pocket Tandas
//
//  A cancellable volume ramp driven by a main-run-loop timer (in `.common` mode so
//  it keeps stepping while the user scrolls). `completion` runs only when the ramp
//  finishes naturally; `cancel()` stops it WITHOUT calling completion — that's what
//  lets Resume abort the scheduled stop atomically (everything runs on the main
//  thread, so there's no race).
//
//  The ramp is linear in amplitude unless the caller passes a `shape`; the DJ
//  fade-out passes FadeCurve below.
//

import Foundation

/// Shape of the DJ fade-out.
///
/// A straight amplitude ramp spends most of its length inaudibly close to full
/// volume and then falls off a cliff at the end; a constant-dB ramp is even, but
/// drops the music out of the room in its first half. This sits between them —
/// the geometric mean of the two, which is exactly their midpoint in dB — so the
/// fade is audible throughout and still lands on true silence.
enum FadeCurve {
    /// Range the constant-dB reference spends over the whole fade.
    private static let dBRange: Float = 60
    /// 0 = straight amplitude ramp, 1 = constant-dB ramp. Halfway between.
    private static let blend: Float = 0.5

    /// Remaining level (1 → 0) at normalized time `x`.
    static func level(atProgress x: Float) -> Float {
        let x = x.clamped(to: 0...1)
        guard x < 1 else { return 0 }
        let straight = 1 - x
        let constantDB = pow(10, -dBRange * x / 20)
        return pow(straight, 1 - blend) * pow(constantDB, blend)
    }

    /// How far along the ramp is at `x`, for FadeController's interpolation.
    static func easedProgress(_ x: Float) -> Float { 1 - level(atProgress: x) }
}

final class FadeController {
    private var timer: Timer?
    private(set) var isRunning = false

    /// `shape` remaps elapsed progress (0…1) to progress along the from → to
    /// interval; the default passes it straight through, giving a linear ramp.
    func ramp(from: Float,
              to: Float,
              duration: TimeInterval,
              steps: Int = 60,
              shape: @escaping (Float) -> Float = { $0 },
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
            apply(from + (to - from) * shape(progress))
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
