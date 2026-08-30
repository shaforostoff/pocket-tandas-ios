// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueView.swift
//  Pocket Tandas
//
//  Bottom half of the main screen: the live play queue. Tap a track to play it,
//  swipe left to remove, long-press to drag-reorder. The currently playing track
//  can't be removed, and a reorder that would relocate it is rejected by
//  PlayQueue (by identity) — not via `.moveDisabled`, which corrupts `.onMove`
//  offsets when a drag crosses the pinned row.
//

import SwiftUI

struct QueueView: View {
    @Environment(PlaybackEngine.self) private var engine
    @Environment(PlayQueue.self) private var queue
    @Environment(MetadataService.self) private var metadata

    var body: some View {
        if queue.items.isEmpty {
            ContentUnavailableView("Play Queue", systemImage: "music.note.list",
                                   description: Text("Swipe a track right in the browser to add it here."))
        } else {
            List {
                ForEach(queue.items) { item in
                    let isCurrent = item.id == engine.state.currentItemID
                    QueueRowView(item: item,
                                 metadata: metadata.snapshot(forKey: item.trackKey),
                                 isCurrent: isCurrent,
                                 isFading: isCurrent && engine.state.isFadingOut)
                        .onTapGesture { engine.requestPlay(item) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .deleteDisabled(isCurrent)
                }
                .onDelete { queue.remove(atOffsets: $0) }
                .onMove { source, destination in
                    ptLog("onMove src=\(Array(source)) dst=\(destination) pinned=\(engine.state.currentItemID?.uuidString.prefix(4) ?? "nil")")
                    ptLog("  before: \(queue.debugOrder)")
                    queue.move(fromOffsets: source, toOffset: destination,
                               pinnedID: engine.state.currentItemID)
                    ptLog("  after:  \(queue.debugOrder)")
                }
            }
            .listStyle(.plain)
        }
    }
}
