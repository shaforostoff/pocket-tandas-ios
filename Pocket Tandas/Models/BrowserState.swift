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
    /// Which source the top-half browser shows: the file system or the device
    /// Music library. Set by the Browse dropdown; the file/music browsers swap in
    /// MainScreenView on this. Resets to `.files` on each presentation.
    enum Source { case files, music }
    var source: Source = .files

    /// The folder the file browser is showing — or a playlist opened as a fake
    /// folder of its tracks. Nil until a base folder is chosen.
    var currentFolder: URL?

    /// The Music-library browser's navigation stack — its `currentFolder`
    /// analogue. Held here (not as the view's @State) so the spot the user
    /// drilled to survives the browser being rebuilt, e.g. on an iPad rotation
    /// between the stacked and side-by-side layouts. Resets per presentation
    /// with the rest of this state.
    let musicModel = MusicBrowseModel()

    // Filter + sort live here rather than as each browser's view @State so they
    // survive the browser being torn down and rebuilt — e.g. when the iPad
    // rotates between the stacked and side-by-side main-screen layouts. Files and
    // Music keep separate sets: their sort defaults and offered options differ
    // (Music has no Filename sort), so a shared field would land on an invalid
    // option when switching source. Reset with the rest on each presentation.
    var fileFilter = ""
    var fileSort: SortOption = .filename
    var fileDirection: SortDirection = .ascending

    var musicFilter = ""
    var musicSort: SortOption = .artist
    var musicDirection: SortDirection = .ascending
}
