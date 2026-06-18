// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MusicBrowserView.swift
//  Pocket Tandas
//
//  The Music-library counterpart of BrowserView for the top half of the main
//  screen. Browses the device library as a node hierarchy (root categories →
//  containers → tracks) via MusicLibrary/MPMediaQuery, reusing BrowserRowView and
//  SortMenu. Tracks play by reference (no copy): tap auditions via the shared
//  PreListenPlayer (Explore), swipe-right enqueues a media QueueItem. Metadata is
//  read straight from each MPMediaItem and seeded into MetadataService, so queue
//  rows / Now Playing display with no file scan.
//

import SwiftUI
import MediaPlayer

@MainActor
struct MusicBrowserView: View {
    let mode: AppMode
    /// Set in Remote Send: swipe-to-add sends a media request to the receiver
    /// instead of enqueuing on this device.
    var remoteQueue: RemoteQueue? = nil

    @Environment(PlayQueue.self) private var queue
    @Environment(MetadataService.self) private var metadata
    @Environment(PreListenPlayer.self) private var preListen
    @Environment(PlaybackEngine.self) private var engine
    @Environment(BrowserState.self) private var browser

    @State private var rawEntries: [MusicEntry] = []
    @State private var displayed: [MusicEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: browser.musicModel.current) { reload() }
        .onChange(of: browser.musicFilter) { _, _ in applyArrange() }
        .onChange(of: browser.musicSort) { _, _ in applyArrange() }
        .onChange(of: browser.musicDirection) { _, _ in applyArrange() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                back()
            } label: {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            .buttonStyle(.borderless)

            if !atRoot {
                TextField("Filter", text: Bindable(browser).musicFilter)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                Text("Music")
                    .font(.headline)
                Spacer()
            }

            if browser.musicModel.current.isTrackList {
                SortMenu(sort: Bindable(browser).musicSort, direction: Bindable(browser).musicDirection, options: sortOptions)
            }

            // While auditioning, a Stop sits at the trailing edge (Explore only).
            if preListen.isPlaying {
                Button(role: .destructive) {
                    preListen.stop()
                } label: {
                    Image(systemName: "stop.fill").imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if atRoot {
            List(MusicCategory.allCases) { category in
                BrowserRowView(title: category.title, systemImage: category.systemImage,
                               isNavigable: true, isContainer: true)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.musicModel.push(.category(category)) }
            }
            .listStyle(.plain)
        } else if displayed.isEmpty {
            ContentUnavailableView(
                browser.musicFilter.isEmpty ? "Nothing Here" : "No Matches",
                systemImage: "music.note",
                description: Text(browser.musicFilter.isEmpty
                                  ? "No music in this part of your library."
                                  : "Nothing matches “\(browser.musicFilter)”."))
            .frame(maxHeight: .infinity)
        } else {
            List(displayed) { entry in
                BrowserRowView(title: entry.title, systemImage: entry.systemImage,
                               isNavigable: entry.isNavigable, isContainer: entry.isNavigable,
                               metadata: entry.snapshot,
                               isPlaying: isAuditioning(entry))
                    .contentShape(Rectangle())
                    .onTapGesture { tap(entry) }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { add(entry) } label: {
                            Label("Add", systemImage: "text.append")
                        }
                        .tint(.green)
                    }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Navigation

    private var atRoot: Bool {
        if case .root = browser.musicModel.current { return true }
        return false
    }

    /// Back pops a level; at the Music root it returns to the file browser (the
    /// source the user came from).
    private func back() {
        if browser.musicModel.canGoUp { browser.musicModel.pop() } else { browser.source = .files }
    }

    private func isAuditioning(_ entry: MusicEntry) -> Bool {
        guard let current = preListen.currentURL, let url = entry.assetURL else { return false }
        return current == url
    }

    /// Sort options: the metadata-capable subset (no filename — there are none).
    /// Inside a playlist, its own listed order is offered and is the default.
    private var sortOptions: [SortOption] {
        browser.musicModel.current.isPlaylist
            ? [.listed, .artist, .dateYear, .genre, .bpm]
            : [.artist, .dateYear, .genre, .bpm]
    }

    // MARK: - Loading

    private func reload() {
        switch browser.musicModel.current {
        case .root:
            rawEntries = []
        case .category(.songs):
            rawEntries = makeTrackEntries(MusicLibrary.tracks(in: browser.musicModel.current))
        case .category(let category):
            rawEntries = MusicLibrary.containers(for: category).map(makeContainerEntry)
        case .container:
            rawEntries = makeTrackEntries(MusicLibrary.tracks(in: browser.musicModel.current))
        }
        // Keep the sort valid for the destination: a playlist defaults to its own
        // listed order; folders/track lists never use it.
        if browser.musicModel.current.isPlaylist {
            browser.musicSort = .listed
            browser.musicDirection = .ascending
        } else if browser.musicSort == .listed {
            browser.musicSort = .artist
            browser.musicDirection = .ascending
        }
        browser.musicFilter = ""
        applyArrange()
    }

    private func makeTrackEntries(_ items: [MPMediaItem]) -> [MusicEntry] {
        items.enumerated().map { offset, item in
            let snapshot = TrackMetadataSnapshot(mediaItem: item)
            return MusicEntry(id: "medialib:\(item.persistentID)#\(offset)", kind: .track,
                              title: item.title ?? "Unknown", systemImage: "music.note",
                              isNavigable: false, snapshot: snapshot, mediaItem: item)
        }
    }

    private func makeContainerEntry(_ container: MusicContainer) -> MusicEntry {
        let ident = container.persistentID.map(String.init) ?? container.filterValue ?? container.title
        return MusicEntry(id: "con:\(container.kind):\(ident)", kind: .container(container),
                          title: container.title, systemImage: container.systemImage,
                          isNavigable: true, snapshot: nil, mediaItem: nil)
    }

    // MARK: - Filter + sort

    private func applyArrange() {
        displayed = arranged()
        syncPrelistenListing()
    }

    private func arranged() -> [MusicEntry] {
        let needle = browser.musicFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = rawEntries
        if !needle.isEmpty {
            entries = entries.filter { entry in
                if entry.title.localizedStandardContains(needle) { return true }
                guard let m = entry.snapshot else { return false }
                return [m.title, m.artist, m.genre].compactMap { $0 }
                    .contains { $0.localizedStandardContains(needle) }
            }
        }
        // Container lists sort alphabetically (like folders); track lists use the
        // chosen metadata sort, with listed order preserved for playlists.
        guard browser.musicModel.current.isTrackList else {
            return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        if browser.musicSort == .listed {
            return browser.musicDirection == .descending ? entries.reversed() : entries
        }
        var sorted = entries.sorted { ascending($0, $1) }
        if browser.musicDirection == .descending { sorted.reverse() }
        return sorted
    }

    /// Ascending order for the metadata sorts, mirroring DirectoryLister's chains
    /// (each option falls through to the next on a tie; title is the final tiebreak).
    private func ascending(_ a: MusicEntry, _ b: MusicEntry) -> Bool {
        var c: ComparisonResult
        switch browser.musicSort {
        case .dateYear:
            c = cmpYear(a, b)
        case .genre:
            c = cmpGenre(a, b)
            if c == .orderedSame { c = cmpYear(a, b) }
        case .artist:
            c = cmpArtist(a, b)
            if c == .orderedSame { c = cmpGenre(a, b) }
            if c == .orderedSame { c = cmpYear(a, b) }
        case .bpm:
            c = cmpBPM(a, b)
            if c == .orderedSame { c = cmpArtist(a, b) }
            if c == .orderedSame { c = cmpYear(a, b) }
        case .listed, .filename:
            c = .orderedSame
        }
        if c == .orderedSame { c = a.title.localizedStandardCompare(b.title) }
        return c == .orderedAscending
    }

    private func cmpYear(_ a: MusicEntry, _ b: MusicEntry) -> ComparisonResult {
        let x = a.snapshot?.year ?? Int.min, y = b.snapshot?.year ?? Int.min
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
    private func cmpBPM(_ a: MusicEntry, _ b: MusicEntry) -> ComparisonResult {
        let x = a.snapshot?.bpm ?? Int.min, y = b.snapshot?.bpm ?? Int.min
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
    private func cmpGenre(_ a: MusicEntry, _ b: MusicEntry) -> ComparisonResult {
        (a.snapshot?.genre ?? "").localizedStandardCompare(b.snapshot?.genre ?? "")
    }
    private func cmpArtist(_ a: MusicEntry, _ b: MusicEntry) -> ComparisonResult {
        (a.snapshot?.artist ?? "").localizedStandardCompare(b.snapshot?.artist ?? "")
    }

    // MARK: - Prelisten

    private func syncPrelistenListing() {
        guard mode.isExploreLike else { return }
        preListen.updateListing(displayed.compactMap(\.assetURL), folder: browser.musicModel.current.contextURL)
    }

    // MARK: - Actions

    private func tap(_ entry: MusicEntry) {
        switch entry.kind {
        case .container(let container):
            browser.musicModel.push(.container(container))
        case .track:
            guard mode.isExploreLike, let url = entry.assetURL else { return }
            switch engine.state {
            case .playing, .fadingOut:
                return                       // don't interrupt active queue playback
            case .paused:
                engine.stop()                // stop the paused queue to make room
            case .idle:
                break
            }
            preListen.play(url, in: browser.musicModel.current.contextURL)
        }
    }

    private func add(_ entry: MusicEntry) {
        let items: [MPMediaItem]
        switch entry.kind {
        case .container(let container):
            items = MusicLibrary.tracks(in: .container(container))
        case .track:
            items = entry.mediaItem.map { [$0] } ?? []
        }
        guard !items.isEmpty else { return }
        if mode.isRemoteSend, let remoteQueue {
            // Remote Send: the receiver resolves these in its own (synced) library.
            remoteQueue.addTracks(items.map(Self.mediaAddRequest))
        } else {
            enqueue(items)
        }
    }

    /// Build a media add request from a library item — metadata only. The receiver
    /// matches it against its own library; the per-device persistentID is not sent.
    private static func mediaAddRequest(for item: MPMediaItem) -> TrackAddRequest {
        let year = item.releaseDate.map { Calendar.current.component(.year, from: $0) }
        return TrackAddRequest(source: .mediaLibrary, artist: item.artist, title: item.title,
                               dateText: year.map(String.init), year: year,
                               album: item.albumTitle, durationHint: item.playbackDuration)
    }

    /// Enqueue library items by reference — no copy. DRM/cloud items (no asset URL)
    /// are skipped. Each item's snapshot is seeded so its queue row shows metadata.
    private func enqueue(_ items: [MPMediaItem]) {
        var queued: [QueueItem] = []
        for item in items {
            guard let assetURL = item.assetURL else { continue }
            let ref = MediaRef(persistentID: item.persistentID, assetURL: assetURL,
                               displayTitle: item.title ?? "Unknown", duration: item.playbackDuration)
            let snapshot = TrackMetadataSnapshot(mediaItem: item)
            let queueItem = QueueItem(media: ref, snapshot: snapshot)
            metadata.inject(snapshot, forKey: queueItem.trackKey)
            queued.append(queueItem)
        }
        guard !queued.isEmpty else { return }
        queue.enqueue(contentsOf: queued)
    }
}
