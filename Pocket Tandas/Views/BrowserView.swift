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
import MediaPlayer

@MainActor
struct BrowserView: View {
    let mode: AppMode
    /// Set in Remote Send: swipe-to-add sends a request to the receiver instead
    /// of enqueuing on this device.
    var remoteQueue: RemoteQueue? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(PlayQueue.self) private var queue
    @Environment(MetadataService.self) private var metadata
    @Environment(BrowserState.self) private var browser
    @Environment(PlaybackEngine.self) private var engine
    @Environment(PreListenPlayer.self) private var preListen
    @Environment(\.dismiss) private var dismiss

    @State private var rawEntries: [LibraryEntry] = []
    @State private var filterText = ""
    @State private var sort: SortOption = .filename
    @State private var direction: SortDirection = .ascending
    @State private var showingPicker = false
    @State private var musicAccessDenied = false
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
        .alert("Music Access Needed", isPresented: $musicAccessDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow Pocket Tandas to access your music in Settings to add tracks from your library.")
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
                    browseControl
                }

                // While a browser audition is playing, a Stop sits at the trailing
                // edge (only ever shown in Explore — prelistening can't start
                // elsewhere). Distinct from the queue's Stop/Pause control below.
                if preListen.isPlaying {
                    Button(role: .destructive) {
                        preListen.stop()
                    } label: {
                        Image(systemName: "stop.fill").imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
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
        // The audio files as shown (display order), tagged with where they live —
        // handed to the prelisten player so a finished track advances within this
        // exact arrangement, or stops once the user has moved elsewhere.
        let displayed = DisplayedListing(folder: browser.currentFolder,
                                         urls: entries.filter { $0.kind == .audio }.map(\.url))
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
                                       metadata: entry.isFolder ? nil : metadata.snapshot(for: entry.url, baseURL: library.baseURL),
                                       isPlaying: preListen.currentURL == entry.url)
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
            // After "Back" reloads the parent listing, scroll to the child
            // (folder or playlist) we came from. Consumed on the first reload.
            .onChange(of: rawEntries) { _, newRaw in
                guard let target = scrollTarget else { return }
                scrollTarget = nil
                guard newRaw.contains(where: { $0.id == target }) else { return }
                Task { @MainActor in proxy.scrollTo(target, anchor: .center) }
            }
            // Keep the prelisten player's view of the list current, and on any
            // re-arrange/navigation make sure the playing audition stays visible.
            .onAppear { syncPrelistenListing(displayed) }
            .onChange(of: displayed) { _, new in
                syncPrelistenListing(new)
                scrollToAudition(entries, proxy: proxy)
            }
            // ...and when playback rolls over to the next track on its own — but
            // not on a manual tap, since the tapped row is already on screen.
            .onChange(of: preListen.autoAdvanceCount) { _, _ in
                scrollToAudition(entries, proxy: proxy)
            }
        }
    }

    /// Display-order audio plus its location — the unit the browser pushes to the
    /// prelisten player whenever sort, filter, or folder change.
    private struct DisplayedListing: Equatable {
        let folder: URL?
        let urls: [URL]
    }

    private func syncPrelistenListing(_ listing: DisplayedListing) {
        guard mode.isExploreLike else { return }
        preListen.updateListing(listing.urls, folder: listing.folder)
    }

    /// Center the currently-auditioned file if it's in the shown list. No-op when
    /// nothing is prelistening or it's been filtered out of view.
    private func scrollToAudition(_ entries: [LibraryEntry], proxy: ScrollViewProxy) {
        guard let url = preListen.currentURL,
              entries.contains(where: { $0.id == url }) else { return }
        Task { @MainActor in proxy.scrollTo(url, anchor: .center) }
    }

    private var chooseFolderPrompt: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No Base Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose a folder of music to browse, or add tracks from your Music library.")
            } actions: {
                browsePromptButton
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

    /// Tap routing: folders/playlists drill in; in Explore, tapping an audio file
    /// auditions it (prelistening). A *paused* play queue is stopped first to make
    /// room; an actively *playing* queue wins and the tap is ignored. Outside
    /// Explore an audio tap does nothing (tracks are queued via swipe-right).
    private func tap(_ entry: LibraryEntry) {
        switch entry.kind {
        case .folder, .playlist:
            open(entry)
        case .audio:
            guard mode.isExploreLike else { return }
            switch engine.state {
            case .playing, .fadingOut:
                return                       // don't interrupt active queue playback
            case .paused:
                engine.stop()                // stop the paused queue to make room
            case .idle:
                break
            }
            preListen.play(entry.url, in: browser.currentFolder)
        }
    }

    private func open(_ entry: LibraryEntry) {
        // Folders and playlists drill in (a playlist opens as a fake folder of
        // its tracks); audio is added via swipe-right, not tap.
        guard entry.isNavigable else { return }
        navigate(to: entry.url)
    }

    private func add(_ entry: LibraryEntry) {
        // Remote Send: route adds to the receiver as track requests instead of
        // enqueuing on this device (the receiver honours its own insert anchor).
        if mode.isRemoteSend {
            addToRemote(entry)
            return
        }
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

    /// Remote Send: turn a swiped entry into TrackAddRequests and send them to the
    /// receiver. Folders/playlists expand to their audio tracks in the browser's
    /// current order; the receiver resolves each to a local file.
    private func addToRemote(_ entry: LibraryEntry) {
        guard let remoteQueue else { return }
        switch entry.kind {
        case .audio:
            remoteQueue.addTracks([trackAddRequest(for: entry.url)])
        case .playlist:
            let urls = PlaylistParser.parse(playlistURL: entry.url)
            remoteQueue.addTracks(urls.map(trackAddRequest(for:)))
        case .folder:
            let audio = library.rawEntries(in: entry.url).filter { $0.kind == .audio }
            let urls = DirectoryLister.arrange(audio, filter: "", sort: sort, direction: direction,
                                               metadata: { metadata.snapshot(for: $0, baseURL: library.baseURL) })
                .map(\.url)
            remoteQueue.addTracks(urls.map(trackAddRequest(for:)))
        }
    }

    /// Build a track request from the file's base-relative path plus whatever
    /// metadata is cached locally (the receiver uses it for fallback matching).
    private func trackAddRequest(for url: URL) -> TrackAddRequest {
        let relativePath = StableTrackID.relativePath(for: url, baseURL: library.baseURL) ?? url.lastPathComponent
        let snapshot = metadata.snapshot(for: url, baseURL: library.baseURL)
        return TrackAddRequest(relativePath: relativePath,
                               artist: snapshot?.artist,
                               title: snapshot?.title,
                               dateText: snapshot?.dateText,
                               year: snapshot?.year)
    }

    /// The "Browse" control in the header: a Files/Music dropdown. In Remote Send,
    /// Music tracks are sent to the receiver as metadata requests it resolves in its
    /// own (synced) library — so the source is offered there too.
    @ViewBuilder
    private var browseControl: some View {
        Menu {
            sourceMenuItems
        } label: {
            Image(systemName: "folder.badge.gearshape").imageScale(.large)
        }
        .buttonStyle(.borderless)
    }

    /// The prominent action on the empty-state prompt, mirroring `browseControl`
    /// for when no base folder has been chosen yet.
    @ViewBuilder
    private var browsePromptButton: some View {
        Menu {
            sourceMenuItems
        } label: {
            Text("Browse…")
        }
        .buttonStyle(.borderedProminent)
    }

    /// The two browse sources: the file/folder picker and the device Music library.
    @ViewBuilder
    private var sourceMenuItems: some View {
        Button { showingPicker = true } label: {
            Label("Files", systemImage: "folder")
        }
        Button { chooseMusic() } label: {
            Label("Music", systemImage: "music.note")
        }
    }

    /// Request Music-library access, then switch the top half to the in-app Music
    /// browser. A denial (or restriction) surfaces the access alert instead.
    private func chooseMusic() {
        Task { @MainActor in
            if await MediaLibraryImporter.requestAuthorization() == .authorized {
                browser.source = .music
            } else {
                musicAccessDenied = true
            }
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
