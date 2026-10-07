// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  M4ATagMapper.swift
//  Pocket Tandas
//
//  A source file's tags, restated as the iTunes items an .m4a carries — for the
//  compressed copy a Remote Send phone makes of a track the receiver lacks (see
//  AACTranscoder). The copy has to arrive tagged: the receiver sorts, labels and
//  levels it by those tags, and its date, BPM and ReplayGain come from nowhere
//  else.
//
//  Three sources, in priority order:
//    1. Items already in the iTunes key spaces (an .m4a source) go across as they
//       are — including the freeform ones TangoTunes writes (BPM, ReplayGain).
//    2. ID3 frames (MP3, and AAC/ADTS files), by an explicit frame → atom table,
//       with AVFoundation's common keys as the fallback for anything else it reads.
//       TXXX frames become freeform atoms under the same description.
//    3. FLAC's Vorbis comments, read here directly: AVFoundation decodes FLAC audio
//       but does not surface a single one of its tags (checked on macOS 14).
//
//  The first source to supply a field wins it. Encoder bookkeeping (gapless
//  padding, encoder settings, encoding tool) describes the source's encode, not
//  the new one, and is left behind.
//

import Foundation
import AVFoundation

enum M4ATagMapper {

    static func items(for asset: AVURLAsset) async -> [AVMetadataItem] {
        var source: [AVMetadataItem] = []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            source += (try? await asset.loadMetadata(for: format)) ?? []
        }

        var tags = Builder()
        for item in source where isITunes(item) {
            await tags.copy(item)
        }
        for rule in rules {
            for item in source where !isITunes(item) && rule.matches(item) {
                if await tags.add(item, as: rule) { break }
            }
        }
        for item in source where item.identifier == .id3MetadataUserText {
            let extras = try? await item.load(.extraAttributes)
            guard let name = extras?[.info] as? String, !name.isEmpty,
                  let value = try? await item.load(.stringValue) else { continue }
            tags.text(freeform(name), value)
        }
        if asset.url.pathExtension.lowercased() == "flac" {
            for (name, value) in FLACTags.comments(in: asset.url) {
                tags.vorbis(name, value)
            }
            if let picture = FLACTags.frontCover(in: asset.url) {
                tags.image(picture)
            }
        }
        return tags.items
    }

    // MARK: - Rules

    /// One iTunes atom, and the source items that can fill it, best first.
    private struct Rule {
        enum Kind { case text, integer, indexPair, image }
        let target: AVMetadataIdentifier
        let kind: Kind
        let sources: [AVMetadataIdentifier]
        let common: AVMetadataKey?

        func matches(_ item: AVMetadataItem) -> Bool {
            if let id = item.identifier, sources.contains(id) { return true }
            if let common, item.commonKey == common { return true }
            return false
        }
    }

    /// Sources within a rule are tried in the order listed, so for the date the
    /// full recording time beats a bare year — the same order MetadataKeys reads.
    private static let rules: [Rule] = [
        Rule(target: .iTunesMetadataSongName, kind: .text,
             sources: [.id3MetadataTitleDescription], common: .commonKeyTitle),
        Rule(target: .iTunesMetadataArtist, kind: .text,
             sources: [.id3MetadataLeadPerformer], common: .commonKeyArtist),
        Rule(target: .iTunesMetadataAlbumArtist, kind: .text,
             sources: [.id3MetadataBand], common: nil),
        Rule(target: .iTunesMetadataAlbum, kind: .text,
             sources: [.id3MetadataAlbumTitle], common: .commonKeyAlbumName),
        Rule(target: .iTunesMetadataComposer, kind: .text,
             sources: [.id3MetadataComposer], common: .commonKeyCreator),
        Rule(target: .iTunesMetadataUserGenre, kind: .text,
             sources: [.id3MetadataContentType], common: .commonKeyType),
        Rule(target: .iTunesMetadataReleaseDate, kind: .text,
             sources: [.id3MetadataRecordingTime, .id3MetadataYear, .id3MetadataReleaseTime,
                       .id3MetadataOriginalReleaseTime], common: .commonKeyCreationDate),
        Rule(target: .iTunesMetadataUserComment, kind: .text,
             sources: [.id3MetadataComments], common: nil),
        Rule(target: .iTunesMetadataBeatsPerMin, kind: .integer,
             sources: [.id3MetadataBeatsPerMinute], common: nil),
        Rule(target: .iTunesMetadataGrouping, kind: .text,
             sources: [.id3MetadataContentGroupDescription], common: nil),
        Rule(target: .iTunesMetadataTrackNumber, kind: .indexPair,
             sources: [.id3MetadataTrackNumber], common: nil),
        Rule(target: .iTunesMetadataDiscNumber, kind: .indexPair,
             sources: [.id3MetadataPartOfASet], common: nil),
        Rule(target: .iTunesMetadataLyrics, kind: .text,
             sources: [.id3MetadataUnsynchronizedLyric], common: nil),
        Rule(target: .iTunesMetadataCopyright, kind: .text,
             sources: [.id3MetadataCopyright], common: .commonKeyCopyrights),
        Rule(target: .iTunesMetadataPublisher, kind: .text,
             sources: [.id3MetadataPublisher], common: .commonKeyPublisher),
        Rule(target: .iTunesMetadataCoverArt, kind: .image,
             sources: [.id3MetadataAttachedPicture], common: .commonKeyArtwork),
    ]

    /// Vorbis comment names (upper-cased) with an atom of their own. The rest go
    /// across as freeform atoms under their own name.
    private static let vorbisRules: [String: (AVMetadataIdentifier, Rule.Kind)] = [
        "TITLE": (.iTunesMetadataSongName, .text),
        "ARTIST": (.iTunesMetadataArtist, .text),
        "ALBUMARTIST": (.iTunesMetadataAlbumArtist, .text),
        "ALBUM ARTIST": (.iTunesMetadataAlbumArtist, .text),
        "ALBUM": (.iTunesMetadataAlbum, .text),
        "COMPOSER": (.iTunesMetadataComposer, .text),
        "GENRE": (.iTunesMetadataUserGenre, .text),
        "DATE": (.iTunesMetadataReleaseDate, .text),
        "YEAR": (.iTunesMetadataReleaseDate, .text),
        "COMMENT": (.iTunesMetadataUserComment, .text),
        "DESCRIPTION": (.iTunesMetadataUserComment, .text),
        "BPM": (.iTunesMetadataBeatsPerMin, .integer),
        "TEMPO": (.iTunesMetadataBeatsPerMin, .integer),
        "GROUPING": (.iTunesMetadataGrouping, .text),
        "TRACKNUMBER": (.iTunesMetadataTrackNumber, .indexPair),
        "DISCNUMBER": (.iTunesMetadataDiscNumber, .indexPair),
        "LYRICS": (.iTunesMetadataLyrics, .text),
        "UNSYNCEDLYRICS": (.iTunesMetadataLyrics, .text),
        "COPYRIGHT": (.iTunesMetadataCopyright, .text),
        "PUBLISHER": (.iTunesMetadataPublisher, .text),
        "LABEL": (.iTunesMetadataPublisher, .text),
    ]

    /// Vorbis names that only ever qualify another field, or describe the source
    /// encode.
    private static let vorbisSkipped: Set<String> = ["TRACKTOTAL", "TOTALTRACKS", "DISCTOTAL",
                                                     "TOTALDISCS", "ENCODER", "ENCODED-BY",
                                                     "ENCODEDBY", "VENDOR"]

    /// iTunes items that belong to the source's encode: its gapless padding, its
    /// encoder settings, the encoder's name.
    private static let droppedITunes: Set<AVMetadataIdentifier> =
        Set(["iTunSMPB", "Encoding Params"].map(freeform)).union([.iTunesMetadataEncodingTool])

    private static let longFormKeySpace = AVMetadataKeySpace(rawValue: "itlk")

    private static func isITunes(_ item: AVMetadataItem) -> Bool {
        item.keySpace == .iTunes || item.keySpace == longFormKeySpace
    }

    /// `----:com.apple.iTunes:<name>`, the atom TangoTunes and every ReplayGain
    /// tool use for fields iTunes has no atom for.
    private static func freeform(_ name: String) -> AVMetadataIdentifier {
        // ReplayGain is read back by its lower-case m4a name (see MetadataKeys), the
        // way taggers write it in an m4a; Vorbis spells it in capitals.
        let key = name.lowercased().hasPrefix("replaygain_") ? name.lowercased() : name
        return AVMetadataItem.identifier(forKey: "com.apple.iTunes.\(key)" as NSString,
                                         keySpace: longFormKeySpace)
            ?? AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.\(key)")
    }

    // MARK: - Building

    private struct Builder {
        private(set) var items: [AVMetadataItem] = []
        private var taken: Set<AVMetadataIdentifier> = []
        /// The total that rides with a Vorbis track or disc number, seen in any order.
        private var totals: [AVMetadataIdentifier: Int] = [:]

        /// An iTunes item, with its value read now so the writer holds bytes rather
        /// than a lazy reference into the source file.
        mutating func copy(_ item: AVMetadataItem) async {
            guard let id = item.identifier, !taken.contains(id),
                  !M4ATagMapper.droppedITunes.contains(id),
                  let value = try? await item.load(.value) else { return }
            let copy = AVMutableMetadataItem()
            copy.identifier = id
            copy.value = value
            copy.dataType = item.dataType
            append(copy)
        }

        /// Fill `rule.target` from `item`. True when the item supplied a value.
        mutating func add(_ item: AVMetadataItem, as rule: Rule) async -> Bool {
            guard !taken.contains(rule.target) else { return true }
            switch rule.kind {
            case .text:
                guard let value = try? await item.load(.stringValue) else { return false }
                return text(rule.target, value)
            case .integer:
                let string = try? await item.load(.stringValue)
                let number = try? await item.load(.numberValue)
                guard let value = number?.intValue ?? string.flatMap(Self.leadingInteger) else { return false }
                return integer(rule.target, value)
            case .indexPair:
                guard let value = try? await item.load(.stringValue) else { return false }
                return indexPair(rule.target, value)
            case .image:
                guard let data = try? await item.load(.dataValue) else { return false }
                return image(data)
            }
        }

        mutating func vorbis(_ name: String, _ value: String) {
            let upper = name.uppercased()
            switch upper {
            case "TRACKTOTAL", "TOTALTRACKS": noteTotal(value, for: .iTunesMetadataTrackNumber)
            case "DISCTOTAL", "TOTALDISCS": noteTotal(value, for: .iTunesMetadataDiscNumber)
            default: break
            }
            guard !M4ATagMapper.vorbisSkipped.contains(upper) else { return }
            guard let (target, kind) = M4ATagMapper.vorbisRules[upper] else {
                text(M4ATagMapper.freeform(name), value)
                return
            }
            switch kind {
            case .text: text(target, value)
            case .integer: if let n = Self.leadingInteger(value) { integer(target, n) }
            case .indexPair: indexPair(target, value)
            case .image: break
            }
        }

        @discardableResult
        mutating func text(_ id: AVMetadataIdentifier, _ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !taken.contains(id) else { return false }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = trimmed as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            append(item)
            return true
        }

        /// `tmpo` is a 16-bit integer atom; a fractional BPM rounds.
        @discardableResult
        mutating func integer(_ id: AVMetadataIdentifier, _ value: Int) -> Bool {
            guard value > 0, value <= Int(Int16.max), !taken.contains(id) else { return false }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = NSNumber(value: Int16(value))
            item.dataType = kCMMetadataBaseDataType_SInt16 as String
            append(item)
            return true
        }

        /// `trkn` / `disk`: "3/12" (ID3) or "3" plus a separate total (Vorbis), as
        /// the eight-byte binary the atoms hold.
        @discardableResult
        mutating func indexPair(_ id: AVMetadataIdentifier, _ text: String) -> Bool {
            let parts = text.split(separator: "/").map { Self.leadingInteger(String($0)) }
            guard let index = parts.first ?? nil, index > 0, index <= Int(UInt16.max),
                  !taken.contains(id) else { return false }
            let total = min((parts.count > 1 ? parts[1] : nil) ?? totals[id] ?? 0, Int(UInt16.max))
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = Self.pairData(index, total) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            append(item)
            return true
        }

        @discardableResult
        mutating func image(_ data: Data) -> Bool {
            guard !data.isEmpty, !taken.contains(.iTunesMetadataCoverArt) else { return false }
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataCoverArt
            item.value = data as NSData
            item.dataType = (data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                             ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
            append(item)
            return true
        }

        private mutating func noteTotal(_ value: String, for id: AVMetadataIdentifier) {
            guard let total = Self.leadingInteger(value), total > 0 else { return }
            totals[id] = total
            // The number may already be in, from a comment that came first.
            guard let index = items.firstIndex(where: { $0.identifier == id }),
                  let data = items[index].dataValue, data.count >= 6 else { return }
            let number = Int(data[2]) << 8 | Int(data[3])
            let updated = AVMutableMetadataItem()
            updated.identifier = id
            updated.value = Self.pairData(number, min(total, Int(UInt16.max))) as NSData
            updated.dataType = kCMMetadataBaseDataType_RawData as String
            items[index] = updated
        }

        private mutating func append(_ item: AVMutableMetadataItem) {
            guard let id = item.identifier else { return }
            taken.insert(id)
            items.append(item)
        }

        private static func pairData(_ index: Int, _ total: Int) -> Data {
            Data([0, 0, UInt8(index >> 8), UInt8(index & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF), 0, 0])
        }

        /// "118", "118.4", "118 BPM" → 118.
        static func leadingInteger(_ text: String) -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Double(trimmed.prefix { $0.isNumber || $0 == "." }), value.isFinite {
                return Int(value.rounded())
            }
            return nil
        }
    }
}

// MARK: - FLAC

/// The two FLAC metadata blocks that carry tags: VORBIS_COMMENT and PICTURE. They
/// sit ahead of the audio, so this reads the file's head only, a block at a time.
enum FLACTags {
    private static let vorbisComment: UInt8 = 4
    private static let picture: UInt8 = 6

    /// Every comment as (name, value), in file order.
    static func comments(in url: URL) -> [(String, String)] {
        guard let block = blocks(in: url).first(where: { $0.type == vorbisComment })?.body else { return [] }
        var reader = ByteReader(block)
        guard let vendorLength = reader.uint32LE(), reader.skip(Int(vendorLength)),
              let count = reader.uint32LE() else { return [] }
        var result: [(String, String)] = []
        for _ in 0..<min(Int(count), 10_000) {
            guard let length = reader.uint32LE(), let bytes = reader.take(Int(length)),
                  let comment = String(data: bytes, encoding: .utf8),
                  let equals = comment.firstIndex(of: "=") else { break }
            result.append((String(comment[..<equals]), String(comment[comment.index(after: equals)...])))
        }
        return result
    }

    /// The front cover, or failing that the first picture of any kind.
    static func frontCover(in url: URL) -> Data? {
        var first: Data?
        for block in blocks(in: url) where block.type == picture {
            var reader = ByteReader(block.body)
            guard let kind = reader.uint32BE(),
                  let mimeLength = reader.uint32BE(), reader.skip(Int(mimeLength)),
                  let descriptionLength = reader.uint32BE(), reader.skip(Int(descriptionLength)),
                  reader.skip(16),                       // width, height, depth, colours
                  let length = reader.uint32BE(), let data = reader.take(Int(length)) else { continue }
            if kind == 3 { return data }
            if first == nil { first = data }
        }
        return first
    }

    private static func blocks(in url: URL) -> [(type: UInt8, body: Data)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return [] }
        var result: [(UInt8, Data)] = []
        // A real file has a handful; the bound only stops a corrupt one looping.
        for _ in 0..<64 {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if type == vorbisComment || type == picture {
                guard let body = try? handle.read(upToCount: length), body.count == length else { break }
                result.append((type, body))
            } else {
                guard let offset = try? handle.offset() else { break }
                try? handle.seek(toOffset: offset + UInt64(length))
            }
            if isLast { break }
        }
        return result
    }

    private struct ByteReader {
        private let data: Data
        private var position: Int

        init(_ data: Data) {
            self.data = data
            self.position = data.startIndex
        }

        mutating func take(_ count: Int) -> Data? {
            guard count >= 0, position + count <= data.endIndex else { return nil }
            defer { position += count }
            return data.subdata(in: position..<position + count)
        }

        mutating func skip(_ count: Int) -> Bool { take(count) != nil }

        mutating func uint32LE() -> UInt32? {
            take(4).map { $0.reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        }

        mutating func uint32BE() -> UInt32? {
            take(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }
    }
}
