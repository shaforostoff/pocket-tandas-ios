// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  QueueView.swift
//  Pocket Tandas
//
//  Bottom half of the main screen: the live play queue. Tap a track to play it,
//  swipe left to remove, swipe right to set it as the insert anchor, long-press
//  to drag-reorder. The currently playing track can't be removed, can't be made
//  the anchor, and a reorder that would relocate it is rejected by PlayQueue (by
//  identity) — not via `.moveDisabled`, which corrupts `.onMove` offsets when a
//  drag crosses the pinned row.
//

import SwiftUI

struct QueueView: View {
    @Environment(PlaybackEngine.self) private var engine
    @Environment(PlayQueue.self) private var queue
    @Environment(MetadataService.self) private var metadata

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if queue.items.isEmpty {
                    ContentUnavailableView("Play Queue", systemImage: "music.note.list",
                                           description: Text("Swipe a track right in the browser to add it here."))
                } else {
                    List {
                        ForEach(queue.items) { item in
                            let isCurrent = item.id == engine.state.currentItemID
                            let isAnchor = item.id == queue.anchorID
                            QueueRowView(item: item,
                                         metadata: metadata.snapshot(forKey: item.trackKey),
                                         isCurrent: isCurrent,
                                         isFading: isCurrent && engine.state.isFadingOut,
                                         isAnchor: isAnchor)
                                .onTapGesture { engine.requestPlay(item) }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .deleteDisabled(isCurrent)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    anchorSwipeButton(for: item, isCurrent: isCurrent, isAnchor: isAnchor)
                                }
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
            // Bring whatever was just added into view. New tracks land at the end
            // normally, but above the insert anchor when one is set — so scroll to
            // the last newly-inserted row (the one nearest the anchor) rather than
            // always the bottom. Additions only: a remove or reorder yields no new
            // id and doesn't scroll.
            .onChange(of: queue.items.map(\.id)) { oldIDs, newIDs in
                let old = Set(oldIDs)
                guard let target = newIDs.last(where: { !old.contains($0) }) else { return }
                Task { @MainActor in
                    withAnimation { proxy.scrollTo(target, anchor: .bottom) }
                }
            }
        }
    }

    /// Leading-swipe action to set or clear the insert anchor. Offered on every
    /// row but the currently playing one — anchoring the playing track would
    /// place new tracks behind the playhead, where they'd never play.
    @ViewBuilder
    private func anchorSwipeButton(for item: QueueItem, isCurrent: Bool, isAnchor: Bool) -> some View {
        if !isCurrent {
            if isAnchor {
                Button {
                    queue.setAnchor(nil)
                } label: {
                    Label("Clear Anchor", systemImage: "xmark")
                }
                .tint(.gray)
            } else {
                Button {
                    queue.setAnchor(item.id)
                } label: {
                    Label("Insert Here", systemImage: "arrow.down.to.line")
                }
                .tint(.accentColor)
            }
        }
    }
}
