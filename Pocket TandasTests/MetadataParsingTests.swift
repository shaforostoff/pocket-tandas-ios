// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  MetadataParsingTests.swift
//  Pocket TandasTests
//
//  Covers the date-resolution rule (comment fallback / year-only) and BPM parse.
//

import XCTest
@testable import Pocket_Tandas

final class MetadataParsingTests: XCTestCase {

    func testFullDateInDateFieldIsUsed() {
        let r = MetadataParsing.resolveDate(dateField: "1935-05-14", commentField: nil)
        XCTAssertEqual(r.dateText, "1935-05-14")
        XCTAssertEqual(r.year, 1935)
    }

    func testIsoTimestampYieldsDatePortion() {
        let r = MetadataParsing.resolveDate(dateField: "1935-05-14T00:00:00", commentField: nil)
        XCTAssertEqual(r.dateText, "1935-05-14")
        XCTAssertEqual(r.year, 1935)
    }

    func testYearOnlyFieldFallsBackToCommentDate() {
        let r = MetadataParsing.resolveDate(dateField: "1935", commentField: "recorded 1935-05-14 by orchestra")
        XCTAssertEqual(r.dateText, "1935-05-14")
        XCTAssertEqual(r.year, 1935)
    }

    func testEmptyDateUsesCommentDate() {
        let r = MetadataParsing.resolveDate(dateField: nil, commentField: "1942-10-09")
        XCTAssertEqual(r.dateText, "1942-10-09")
        XCTAssertEqual(r.year, 1942)
    }

    func testYearOnlyWithNoCommentDateKeepsYear() {
        let r = MetadataParsing.resolveDate(dateField: "1935", commentField: "no date here")
        XCTAssertEqual(r.dateText, "1935")
        XCTAssertEqual(r.year, 1935)
    }

    func testFullDateFieldWinsOverComment() {
        let r = MetadataParsing.resolveDate(dateField: "1935-05-14", commentField: "1999-01-01")
        XCTAssertEqual(r.dateText, "1935-05-14")
        XCTAssertEqual(r.year, 1935)
    }

    func testNoDateAnywhere() {
        let r = MetadataParsing.resolveDate(dateField: nil, commentField: "just a note")
        XCTAssertNil(r.dateText)
        XCTAssertNil(r.year)
    }

    func testBPMParsing() {
        XCTAssertEqual(MetadataParsing.parseBPM("120"), 120)
        XCTAssertEqual(MetadataParsing.parseBPM("120.5"), 120)
        XCTAssertEqual(MetadataParsing.parseBPM("128 BPM"), 128)
        XCTAssertNil(MetadataParsing.parseBPM("abc"))
        XCTAssertNil(MetadataParsing.parseBPM(""))
        XCTAssertNil(MetadataParsing.parseBPM(nil))
        XCTAssertNil(MetadataParsing.parseBPM("0"))
    }

    func testReplayGainParsing() {
        // The reference file (Maragata) carries replaygain_track_gain = "-2.33 dB".
        XCTAssertEqual(MetadataParsing.parseReplayGainGain("-2.33 dB")!, -2.33, accuracy: 0.0001)
        XCTAssertEqual(MetadataParsing.parseReplayGainGain("+1.5 dB")!, 1.5, accuracy: 0.0001)
        XCTAssertEqual(MetadataParsing.parseReplayGainGain("6.00 dB")!, 6.0, accuracy: 0.0001)
        XCTAssertEqual(MetadataParsing.parseReplayGainGain("-7.2")!, -7.2, accuracy: 0.0001)   // unit optional
        XCTAssertEqual(MetadataParsing.parseReplayGainGain("0 dB")!, 0.0, accuracy: 0.0001)
    }

    func testReplayGainRejectsJunkAndImplausibleValues() {
        XCTAssertNil(MetadataParsing.parseReplayGainGain("dB"))
        XCTAssertNil(MetadataParsing.parseReplayGainGain("abc"))
        XCTAssertNil(MetadataParsing.parseReplayGainGain(""))
        XCTAssertNil(MetadataParsing.parseReplayGainGain(nil))
        XCTAssertNil(MetadataParsing.parseReplayGainGain("999 dB"))   // corrupt: out of range
        XCTAssertNil(MetadataParsing.parseReplayGainGain("-120 dB"))  // corrupt: out of range
    }
}
