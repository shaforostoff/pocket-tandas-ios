// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MediaPicker.swift
//  Pocket Tandas
//
//  Bridges UIKit's MPMediaPickerController into SwiftUI so the user can pick
//  tracks from the device Music library (the "Music" choice on the Browse menu).
//  Multi-select, music only, local items only (cloud items hidden — un-downloaded
//  items have no readable asset). Picked items are handed back as MPMediaItems for
//  MediaLibraryImporter to export + enqueue; DRM filtering happens there.
//

import SwiftUI
import MediaPlayer

struct MediaPicker: UIViewControllerRepresentable {
    var onPick: ([MPMediaItem]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        picker.showsCloudItems = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        private let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            parent.onPick(mediaItemCollection.items)
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.onCancel()
        }
    }
}
