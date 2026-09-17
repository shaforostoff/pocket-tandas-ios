// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SavePlaylistButton.swift
//  Pocket Tandas
//
//  Explore-mode control bar button: save the play queue as a playlist.
//
//  WHERE it saves is never asked — it follows what the browser above is showing.
//  Files and folders save an .m3u8 (PlaylistWriter) into a folder chosen from the
//  browsed folder and its parents; the Music library saves a real library playlist
//  (MusicPlaylistSaver). You save to whatever you were just picking tracks from.
//
//  The two destinations hold different things — an .m3u8 can only carry file
//  paths, a library playlist can only carry library tracks — so either save
//  reports what it had to leave behind.
//

import SwiftUI

struct SavePlaylistButton: View {
    @Environment(PlayQueue.self) private var queue
    @Environment(LibraryStore.self) private var library
    @Environment(BrowserState.self) private var browser

    @State private var askingName = false
    @State private var askingFolder = false
    /// Music library only: the typed name already belongs to a playlist this app
    /// made, so the user picks between replacing it and making another.
    @State private var askingReplace = false
    @State private var name = ""
    @State private var isSaving = false
    @State private var resultMessage: String?

    var body: some View {
        // The result alert is hosted on a separate view so it never contends with
        // the name alert for the same presentation slot — as is the replace
        // dialog, which can follow the name alert immediately.
        withReplaceDialog(saveButton)
            .background(
                Color.clear.alert("Save Playlist", isPresented: resultPresented) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(resultMessage ?? "")
                }
            )
    }

    private var saveButton: some View {
        Button {
            name = defaultName
            askingName = true
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(queue.items.isEmpty || isSaving
                  || (!savesToMusicLibrary && folderChain.isEmpty))
        .alert("Save Playlist", isPresented: $askingName) {
            TextField("Playlist name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button(savesToMusicLibrary ? "Save" : "Next") { proceed() }
        } message: {
            Text(nameMessage)
        }
        .confirmationDialog("Save “\(PlaylistWriter.filename(from: name))” in…",
                            isPresented: $askingFolder, titleVisibility: .visible) {
            ForEach(folderChain, id: \.self) { dir in
                Button(dir.lastPathComponent) { saveToFolder(dir) }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    /// The name-collision step exists only where there is a Music library to
    /// collide with, so on macOS the whole modifier drops out rather than being
    /// carried as dead state.
    @ViewBuilder
    private func withReplaceDialog(_ content: some View) -> some View {
        #if os(iOS)
        content.background(
            Color.clear.confirmationDialog(
                "“\(MusicPlaylistSaver.displayName(from: name))” already exists",
                isPresented: $askingReplace, titleVisibility: .visible) {
                    Button("Replace Its Contents") { saveToMusicLibrary(replacingExisting: true) }
                    Button("Save as a New Playlist") { saveToMusicLibrary(replacingExisting: false) }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Pocket Tandas saved a Music playlist with this name before.")
                }
        )
        #else
        content
        #endif
    }

    // MARK: - Destination

    /// Which kind of playlist this save produces — decided entirely by the
    /// browser's current source, never by a prompt. macOS has no Music library,
    /// so it is always the .m3u8 path there.
    private var savesToMusicLibrary: Bool {
        #if os(iOS)
        return browser.source == .music
        #else
        return false
        #endif
    }

    /// The folder to record paths against: the browsed folder, or — when a
    /// playlist is open as a fake folder — the real folder that contains it.
    /// Falls back to the base folder.
    private var currentDirectory: URL? {
        guard let folder = browser.currentFolder else { return library.baseURL }
        return AudioFileTypes.isPlaylist(folder) ? folder.deletingLastPathComponent() : folder
    }

    /// Current folder first, then each parent up to and including the base
    /// folder. Empty when no base folder is set (Save is then disabled, unless
    /// the Music library is the destination and needs no folder at all).
    private var folderChain: [URL] {
        guard let base = library.baseURL?.standardizedFileURL,
              var dir = currentDirectory?.standardizedFileURL else { return [] }
        var chain: [URL] = []
        while true {
            chain.append(dir)
            if dir == base { break }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent == dir { break }       // reached the filesystem root
            dir = parent
        }
        if !chain.contains(base) { chain.append(base) }   // current wasn't under base
        return chain
    }

    // MARK: - Naming

    /// The browsed folder's name for an .m3u8; the Music level being browsed —
    /// an artist, album, genre or playlist — for a library playlist.
    private var defaultName: String {
        let base = savesToMusicLibrary
            ? browser.musicModel.current.title
            : (currentDirectory?.lastPathComponent ?? "")
        return base.isEmpty ? "Playlist" : base
    }

    private var nameMessage: String {
        savesToMusicLibrary
            ? "Name the playlist to create in your Music library."
            : "Name this playlist, then choose where to save it."
    }

    // MARK: - Saving

    private func proceed() {
        guard savesToMusicLibrary else {
            askingFolder = true
            return
        }
        #if os(iOS)
        // Ask before clobbering a playlist we made under this name; a first save
        // under a fresh name goes straight through.
        isSaving = true
        Task { @MainActor in
            let collides = await MusicPlaylistSaver.wouldReplacePlaylist(named: name)
            isSaving = false
            if collides {
                askingReplace = true
            } else {
                saveToMusicLibrary(replacingExisting: false)
            }
        }
        #endif
    }

    private func saveToFolder(_ directory: URL) {
        do {
            let url = try PlaylistWriter.write(items: queue.items, name: name, to: directory)
            var message = "Saved “\(url.lastPathComponent)” to “\(directory.lastPathComponent)”."
            let skipped = queue.items.filter(\.isMediaLibrary).count
            if skipped > 0 {
                message += skipped == 1
                    ? " 1 Music-library track was skipped (only files can be saved to a playlist)."
                    : " \(skipped) Music-library tracks were skipped (only files can be saved to a playlist)."
            }
            resultMessage = message
        } catch {
            resultMessage = "Couldn’t save the playlist: \(error.localizedDescription)"
        }
    }

    #if os(iOS)
    private func saveToMusicLibrary(replacingExisting: Bool) {
        isSaving = true
        let items = queue.items
        let title = name
        Task { @MainActor in
            do {
                let result = try await MusicPlaylistSaver.save(items: items, name: title,
                                                              replacingExisting: replacingExisting)
                resultMessage = describe(result)
                // Show the work: the browser jumps to Playlists — re-reading them
                // if it is already there — so the playlist is on screen behind the
                // confirmation rather than somewhere the user has to go find.
                browser.musicModel.showPlaylists(revealing: result.libraryPlaylistID)
            } catch {
                resultMessage = "Couldn’t save the playlist: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func describe(_ result: MusicPlaylistSaveResult) -> String {
        let tracks = result.submitted == 1 ? "1 track" : "\(result.submitted) tracks"
        var message = result.replacedExisting
            ? "Replaced “\(result.name)” in your Music library with \(tracks)."
            : "Saved \(tracks) to “\(result.name)” in your Music library."

        if result.filesSkipped > 0 {
            message += result.filesSkipped == 1
                ? " 1 file track was skipped (a Music playlist can only hold Music-library tracks)."
                : " \(result.filesSkipped) file tracks were skipped (a Music playlist can only hold "
                  + "Music-library tracks)."
        }
        if !result.unmatched.isEmpty {
            // Name a few rather than reprinting a whole tanda's worth of titles.
            let shown = result.unmatched.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            let rest = result.unmatched.count - min(3, result.unmatched.count)
            message += "\n\nNot found in your library: \(shown)"
            message += rest > 0 ? " and \(rest) more." : "."
        }
        return message
    }
    #endif

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } })
    }
}
