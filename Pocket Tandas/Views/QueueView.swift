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
//  the anchor, and a reorder that would relocate it is rejected (by identity) —
//  not via `.moveDisabled`, which corrupts `.onMove` offsets when a drag crosses
//  the pinned row.
//
//  Source-agnostic via QueuePresenting: it renders the local PlayQueue in
//  DJ/Explore (taps drive the local engine) or the mirror of a remote receiver's
//  queue in Remote Send (taps send commands; the receiver is the source of truth
//  and its broadcast updates the mirror).
//

import SwiftUI

struct QueueView: View {
    let presenter: any QueuePresenting

    var body: some View {
        let rows = presenter.rows
        return ScrollViewReader { proxy in
            Group {
                if rows.isEmpty {
                    ContentUnavailableView(
                        presenter.isRemote ? "Remote Queue" : "Play Queue",
                        systemImage: "music.note.list",
                        description: Text(presenter.isRemote
                                          ? "Swipe a track right in the browser to send it to the connected device."
                                          : "Swipe a track right in the browser to add it here."))
                } else {
                    List {
                        ForEach(rows) { row in
                            QueueRowView(row: row, presenter: presenter)
                                .onTapGesture { presenter.requestPlay(row.id) }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .deleteDisabled(row.isCurrent)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    anchorSwipeButton(for: row)
                                }
                        }
                        .onDelete { offsets in
                            presenter.remove(ids: offsets.map { rows[$0].id })
                        }
                        .onMove { source, destination in
                            presenter.move(ids: source.map { rows[$0].id }, toOffset: destination)
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
            .onChange(of: rows.map(\.id)) { oldIDs, newIDs in
                let old = Set(oldIDs)
                guard let target = newIDs.last(where: { !old.contains($0) }) else { return }
                // Defer past the current runloop turn so List commits the inserted
                // row into its backing collection view before we scroll — a same-turn
                // Task hop runs before that commit, so scrollTo can't find the new row
                // and silently no-ops.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation { proxy.scrollTo(target, anchor: .bottom) }
                }
            }
            // On (re)creation — e.g. an iPad rotation rebuilds this list — bring the
            // currently playing track into view. Deferred for the same reason as the
            // insert scroll above: a freshly built List hasn't committed its rows yet.
            .onAppear {
                guard let currentID = rows.first(where: { $0.isCurrent })?.id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            }
        }
    }

    /// Leading-swipe action to set or clear the insert anchor. Offered on every
    /// row but the currently playing one — anchoring the playing track would
    /// place new tracks behind the playhead, where they'd never play.
    @ViewBuilder
    private func anchorSwipeButton(for row: QueueRowVM) -> some View {
        if !row.isCurrent {
            if row.isAnchor {
                Button {
                    presenter.setAnchor(nil)
                } label: {
                    Label("Clear Anchor", systemImage: "xmark")
                }
                .tint(.gray)
            } else {
                Button {
                    presenter.setAnchor(row.id)
                } label: {
                    Label("Insert Here", systemImage: "arrow.down.to.line")
                }
                .tint(.accentColor)
            }
        }
    }
}
