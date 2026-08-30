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
//  is pinned (cannot be moved or removed).
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
                        .moveDisabled(isCurrent)
                        .deleteDisabled(isCurrent)
                }
                .onDelete { queue.remove(atOffsets: $0) }
                .onMove { queue.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
        }
    }
}
