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
    @Environment(\.dismiss) private var dismiss

    @State private var currentFolder: URL?
    @State private var rawEntries: [LibraryEntry] = []
    @State private var filterText = ""
    @State private var sort: SortOption = .filename
    @State private var direction: SortDirection = .ascending
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if currentFolder != nil {
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
            if currentFolder == nil { currentFolder = library.baseURL }
        }
        .onChange(of: library.baseURL) { _, newValue in
            currentFolder = newValue
        }
        .task(id: currentFolder) {
            loadFolder()
        }
    }

    /// List the folder from disk once, then kick off a metadata scan of its audio.
    private func loadFolder() {
        guard let folder = currentFolder else {
            rawEntries = []
            return
        }
        rawEntries = library.rawEntries(in: folder)
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

            if currentFolder != nil {
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if metadata.isScanningFolder {
                    ProgressView().controlSize(.small)
                }

                SortMenu(sort: $sort, direction: $direction)

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
        // While the folder is still being scanned, metadata-based sorts have no
        // data yet — list in natural filename order and apply the chosen sort
        // once every track's metadata is in (a single reorder, not per-track).
        let deferSort = metadata.isScanningFolder && sort != .filename
        let entries = DirectoryLister.arrange(rawEntries, filter: filterText,
                                              sort: deferSort ? .filename : sort,
                                              direction: deferSort ? .ascending : direction,
                                              metadata: { metadata.snapshot(for: $0, baseURL: library.baseURL) })
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
                        if !entry.isFolder {
                            Button { add(entry) } label: {
                                Label("Add", systemImage: "text.append")
                            }
                            .tint(.green)
                        }
                    }
            }
            .listStyle(.plain)
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
        guard let folder = currentFolder else { return false }
        return !library.isBaseFolder(folder)
    }

    /// True when the displayed folder is the user's chosen base folder.
    private var isAtRoot: Bool {
        guard let folder = currentFolder else { return false }
        return library.isBaseFolder(folder)
    }

    private func goUp() {
        guard let folder = currentFolder, !library.isBaseFolder(folder) else { return }
        currentFolder = folder.deletingLastPathComponent()
        filterText = ""
    }

    private func open(_ entry: LibraryEntry) {
        guard entry.isFolder else { return }   // audio/playlist added via swipe-right
        currentFolder = entry.url
        filterText = ""
    }

    private func add(_ entry: LibraryEntry) {
        switch entry.kind {
        case .audio:
            let key = StableTrackID.key(for: entry.url, baseURL: library.baseURL)
            queue.append(QueueItem(url: entry.url, trackKey: key))
        case .playlist:
            let urls = PlaylistParser.parse(playlistURL: entry.url)
            for url in urls {
                let key = StableTrackID.key(for: url, baseURL: library.baseURL)
                queue.append(QueueItem(url: url, trackKey: key))
            }
            // Scan the referenced tracks' metadata (doesn't disturb folder scan).
            metadata.scan(urls: urls, baseURL: library.baseURL)
        case .folder:
            break
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
