// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  SavePlaylistButton.swift
//  Pocket Tandas
//
//  Explore-mode control bar button: save the play queue as an .m3u8. Tapping it
//  asks for a name, then offers the current browser folder and each parent up to
//  the chosen base folder as the destination. PlaylistWriter records the tracks
//  relative to whichever folder is picked.
//

import SwiftUI

struct SavePlaylistButton: View {
    @Environment(PlayQueue.self) private var queue
    @Environment(LibraryStore.self) private var library
    @Environment(BrowserState.self) private var browser

    @State private var askingName = false
    @State private var askingFolder = false
    @State private var name = ""
    @State private var resultMessage: String?

    var body: some View {
        Button {
            name = defaultName
            askingName = true
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(queue.items.isEmpty || destinations.isEmpty)
        .alert("Save Playlist", isPresented: $askingName) {
            TextField("Playlist name", text: $name)
            Button("Cancel", role: .cancel) { }
            Button("Next") { askingFolder = true }
        } message: {
            Text("Name this playlist, then choose where to save it.")
        }
        .confirmationDialog("Save “\(PlaylistWriter.filename(from: name))” in…",
                            isPresented: $askingFolder, titleVisibility: .visible) {
            ForEach(destinations, id: \.self) { dir in
                Button(dir.lastPathComponent) { save(to: dir) }
            }
            Button("Cancel", role: .cancel) { }
        }
        // Hosted on a separate view so it never contends with the name alert
        // above for the same presentation slot.
        .background(
            Color.clear.alert("Save Playlist", isPresented: resultPresented) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(resultMessage ?? "")
            }
        )
    }

    // MARK: - Destinations

    /// The folder to record paths against: the browsed folder, or — when a
    /// playlist is open as a fake folder — the real folder that contains it.
    /// Falls back to the base folder.
    private var currentDirectory: URL? {
        guard let folder = browser.currentFolder else { return library.baseURL }
        return AudioFileTypes.isPlaylist(folder) ? folder.deletingLastPathComponent() : folder
    }

    /// Current folder first, then each parent up to and including the base
    /// folder. Empty when no base folder is set (Save is then disabled).
    private var destinations: [URL] {
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

    private var defaultName: String {
        let folderName = currentDirectory?.lastPathComponent ?? ""
        return folderName.isEmpty ? "Playlist" : folderName
    }

    // MARK: - Save

    private func save(to directory: URL) {
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

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } })
    }
}
