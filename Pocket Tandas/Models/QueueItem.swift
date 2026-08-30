// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueItem.swift
//  Pocket Tandas
//
//  One entry in the play queue. Identity is a per-insertion UUID, so the same
//  file can appear multiple times and reorder/remove independently. Metadata is
//  not stored here — rows look it up live from MetadataService by `trackKey`, so
//  display updates reactively as scans complete.
//

import Foundation

struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let trackKey: String

    var filename: String { url.lastPathComponent }
}
