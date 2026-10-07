// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  RemoteTransferViews.swift
//  Pocket Tandas
//
//  What a file transfer between the phones looks like: the question put to the
//  sending DJ when the receiver is missing tracks, and a banner on each phone
//  while files are on the air. The banners sit with the other link banners above
//  the queue (see MainScreenView) and carry their own separator, like those.
//

import SwiftUI

/// Sender: the file being sent, with a way to stop — or, briefly, how it went.
struct RemoteSendTransferBanner: View {
    let files: RemoteFileSender

    var body: some View {
        if let progress = files.progress {
            HStack(spacing: 10) {
                if progress.encoding {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: progress.fraction)
                        .frame(width: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sending \(progress.index) of \(progress.count): \(progress.title)")
                        .lineLimit(1)
                    Text(progress.encoding
                         ? "Compressing…"
                         : "\(Self.megabytes(progress.sent)) of \(Self.megabytes(progress.size))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
                Spacer(minLength: 0)
                Button("Stop") { files.cancel() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
        } else if let notice = files.notice {
            Text(notice)
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Receiver: the file arriving now.
struct RemoteReceiveTransferBanner: View {
    let files: RemoteFileReceiver

    var body: some View {
        if let progress = files.progress {
            HStack(spacing: 10) {
                ProgressView(value: progress.fraction)
                    .frame(width: 44)
                Text("Receiving \(progress.name)")
                    .lineLimit(1)
                    .font(.footnote)
                Spacer(minLength: 0)
                Text("\(Int(progress.fraction * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
        }
    }
}

extension View {
    /// The "send these across?" question, whenever the sender has one to ask.
    func remoteTransferOffer(_ files: RemoteFileSender?) -> some View {
        modifier(RemoteTransferOfferAlert(files: files))
    }
}

private struct RemoteTransferOfferAlert: ViewModifier {
    let files: RemoteFileSender?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented, presenting: files?.offer) { offer in
            if offer.compressibleCount > 0 {
                Button("Send Compressed (\(size(offer, compressed: true)))") {
                    files?.accept(compressed: true)
                }
                Button("Send Originals (\(size(offer, compressed: false)))") {
                    files?.accept(compressed: false)
                }
            } else {
                Button("Send (\(size(offer, compressed: false)))") {
                    files?.accept(compressed: false)
                }
            }
            Button("Don’t Send", role: .cancel) { files?.decline() }
        } message: { offer in
            Text(message(offer))
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { files?.offer != nil },
                set: { shown in if !shown { files?.decline() } })
    }

    private var title: String {
        let count = files?.offer?.candidates.count ?? 0
        return count == 1 ? "Track not on the other phone" : "\(count) tracks not on the other phone"
    }

    private func message(_ offer: RemoteFileSender.Offer) -> String {
        let count = offer.candidates.count
        var text = count == 1
            ? "Send it over Bluetooth? It will be saved in the same folder there and added to the queue."
            : "Send them over Bluetooth? They will be saved in the same folders there and added to the queue."
        let heavy = offer.compressibleCount
        if heavy > 0 {
            let which = heavy == count ? (count == 1 ? "It is" : "All are") : "\(heavy) of them are"
            text += "\n\n\(which) above 128 kbps. A compressed copy (AAC, 128 kbps, tags kept) is much quicker to send."
        }
        return text
    }

    private func size(_ offer: RemoteFileSender.Offer, compressed: Bool) -> String {
        RemoteSendTransferBanner.megabytes(offer.totalSize(compressed: compressed))
    }
}
