// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  BrowserView.swift
//  Pocket Tandas
//
//  Top half of the main screen: pick a base folder, browse subfolders, audio
//  files, and playlists, with live filter + sort. Swipe-right to add to the
//  queue is wired in M5.
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BrowserView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayQueue.self) private var queue
    @Environment(MetadataService.self) private var metadata
    @Environment(BrowserState.self) private var browser
    @Environment(\.dismiss) private var dismiss

    @State private var rawEntries: [LibraryEntry] = []
    @State private var filterText = ""
    @State private var sort: SortOption = .filename
    @State private var direction: SortDirection = .ascending
    @State private var showingPicker = false
    /// On "Back", the child we left — so the parent list can scroll back to it.
    @State private var scrollTarget: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if browser.currentFolder != nil {
                entryList
            } else {
                chooseFolderPrompt
            }
        }
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
        .onAppear {
            if browser.currentFolder == nil { navigate(to: library.baseURL) }
        }
        .onChange(of: library.baseURL) { _, newValue in
            navigate(to: newValue)
        }
        .task(id: browser.currentFolder) {
            loadFolder()
        }
    }

    /// List the current location once, then kick off a metadata scan of its
    /// audio. A real folder is read from disk; an opened playlist is parsed into
    /// its tracks — deduped, original order kept — and browsed like a folder.
    private func loadFolder() {
        guard let folder = browser.currentFolder else {
            rawEntries = []
            return
        }
        if AudioFileTypes.isPlaylist(folder) {
            var seen = Set<URL>()
            rawEntries = PlaylistParser.parse(playlistURL: folder)
                .filter { seen.insert($0).inserted }
                .map { LibraryEntry(url: $0, kind: AudioFileTypes.isPlaylist($0) ? .playlist : .audio) }
        } else {
            rawEntries = library.rawEntries(in: folder)
        }
        let audioURLs = rawEntries.filter { $0.kind == .audio }.map(\.url)
        metadata.scanFolder(urls: audioURLs, baseURL: library.baseURL)
    }

    /// Single-row header: back (up a folder, or out to the launcher at the root),
    /// the live filter field, sort, and — only at the root — the folder picker.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if canGoUp { goUp() } else { dismiss() }
            } label: {
                Image(systemName: "chevron.left").imageScale(.large)
            }
            .buttonStyle(.borderless)

            if browser.currentFolder != nil {
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if metadata.isScanningFolder {
                    ProgressView().controlSize(.small)
                }

                SortMenu(sort: $sort, direction: $direction, options: sortOptions)

                if isAtRoot {
                    Button { showingPicker = true } label: {
                        Image(systemName: "folder.badge.gearshape").imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var entryList: some View {
        // Natural order for this place: a playlist keeps its listed order, a
        // folder falls back to filename. While a scan is in flight, metadata-based
        // sorts have no data yet, so hold that natural order and apply the chosen
        // sort once every track's metadata is in (one reorder, not per-track).
        let naturalSort: SortOption = isViewingPlaylist ? .listed : .filename
        let deferSort = metadata.isScanningFolder && sort.usesMetadata
        let entries = DirectoryLister.arrange(rawEntries, filter: filterText,
                                              sort: deferSort ? naturalSort : sort,
                                              direction: deferSort ? .ascending : direction,
                                              metadata: { metadata.snapshot(for: $0, baseURL: library.baseURL) })
        ScrollViewReader { proxy in
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        filterText.isEmpty ? "Empty Folder" : "No Matches",
                        systemImage: "tray",
                        description: Text(filterText.isEmpty
                                          ? "No subfolders, audio, or playlists here."
                                          : "Nothing matches “\(filterText)”."))
                    .frame(maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        BrowserRowView(entry: entry,
                                       metadata: entry.isFolder ? nil : metadata.snapshot(for: entry.url, baseURL: library.baseURL))
                            .contentShape(Rectangle())
                            .onTapGesture { open(entry) }
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
            // After "Back" reloads the parent listing, scroll to the child
            // (folder or playlist) we came from. Consumed on the first reload.
            .onChange(of: rawEntries) { _, newRaw in
                guard let target = scrollTarget else { return }
                scrollTarget = nil
                guard newRaw.contains(where: { $0.id == target }) else { return }
                Task { @MainActor in proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private var chooseFolderPrompt: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No Base Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose a folder of music to browse.")
            } actions: {
                Button("Choose Folder…") { showingPicker = true }
                    .buttonStyle(.borderedProminent)
            }
            if let err = library.accessError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var canGoUp: Bool {
        guard let folder = browser.currentFolder else { return false }
        return !library.isBaseFolder(folder)
    }

    /// True when the displayed folder is the user's chosen base folder.
    private var isAtRoot: Bool {
        guard let folder = browser.currentFolder else { return false }
        return library.isBaseFolder(folder)
    }

    /// True when the current location is a playlist opened as a fake folder.
    private var isViewingPlaylist: Bool {
        guard let folder = browser.currentFolder else { return false }
        return AudioFileTypes.isPlaylist(folder)
    }

    /// Sort options offered here — "Playlist Order" only inside a playlist.
    private var sortOptions: [SortOption] {
        isViewingPlaylist
            ? [.listed, .filename, .dateYear, .genre, .bpm, .artist]
            : [.filename, .dateYear, .genre, .bpm, .artist]
    }

    /// Change location, clear the filter, and keep the sort valid for the
    /// destination: a playlist defaults to its listed order; folders never use it.
    private func navigate(to url: URL?) {
        browser.currentFolder = url
        filterText = ""
        if let url, AudioFileTypes.isPlaylist(url) {
            sort = .listed
            direction = .ascending
        } else if sort == .listed {
            sort = .filename
            direction = .ascending
        }
    }

    private func goUp() {
        guard let folder = browser.currentFolder, !library.isBaseFolder(folder) else { return }
        scrollTarget = folder   // restore the parent list to the item we came from
        navigate(to: folder.deletingLastPathComponent())
    }

    private func open(_ entry: LibraryEntry) {
        // Folders and playlists drill in (a playlist opens as a fake folder of
        // its tracks); audio is added via swipe-right, not tap.
        guard entry.isNavigable else { return }
        navigate(to: entry.url)
    }

    private func add(_ entry: LibraryEntry) {
        switch entry.kind {
        case .audio:
            let key = StableTrackID.key(for: entry.url, baseURL: library.baseURL)
            queue.enqueue(QueueItem(url: entry.url, trackKey: key))
        case .playlist:
            let urls = PlaylistParser.parse(playlistURL: entry.url)
            queue.enqueue(contentsOf: urls.map {
                QueueItem(url: $0, trackKey: StableTrackID.key(for: $0, baseURL: library.baseURL))
            })
            // Scan the referenced tracks' metadata (doesn't disturb folder scan).
            metadata.scan(urls: urls, baseURL: library.baseURL)
        case .folder:
            // The folder's immediate audio files only — no recursion, and any
            // playlists inside are ignored. Ordered by the browser's active sort;
            // metadata sorts fall back to filename for tracks not yet scanned.
            let audio = library.rawEntries(in: entry.url).filter { $0.kind == .audio }
            let urls = DirectoryLister.arrange(audio, filter: "", sort: sort, direction: direction,
                                               metadata: { metadata.snapshot(for: $0, baseURL: library.baseURL) })
                .map(\.url)
            queue.enqueue(contentsOf: urls.map {
                QueueItem(url: $0, trackKey: StableTrackID.key(for: $0, baseURL: library.baseURL))
            })
            metadata.scan(urls: urls, baseURL: library.baseURL)
        }
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first { library.chooseBaseFolder(url) }
        case .failure(let error):
            print("[Browser] folder pick failed: \(error)")
        }
    }
}
