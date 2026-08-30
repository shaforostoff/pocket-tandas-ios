// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  DebugLog.swift
//  Pocket Tandas
//
//  Temporary diagnostic logging for the live-queue / playback investigation.
//  Prints with a "[PT]" prefix in DEBUG builds; compiles to a no-op in release.
//  The message is an @autoclosure, so the (potentially expensive) queue-dump
//  strings are only evaluated when logging is active.
//

import Foundation

#if DEBUG
func ptLog(_ message: @autoclosure () -> String) {
    print("[PT] " + message())
}
#else
@inline(__always) func ptLog(_ message: @autoclosure () -> String) {}
#endif
