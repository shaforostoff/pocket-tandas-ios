// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  BrowserState.swift
//  Pocket Tandas
//
//  Screen-scoped navigation state shared across the main screen. The browser
//  owns where the user currently is; the control bar's Save action reads it to
//  offer that folder (and its parents up to the base folder) as save targets.
//  Created per MainScreenView presentation, so it resets on each entry — same
//  lifetime the browser's own @State had before it was lifted here.
//

import Foundation
import Observation

@Observable
final class BrowserState {
    /// The folder the browser is showing — or a playlist opened as a fake folder
    /// of its tracks. Nil until a base folder is chosen.
    var currentFolder: URL?
}
