// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackAnalysisTests.swift
//  Pocket TandasTests
//
//  Covers the two rules the measuring pass answers to: a tag always beats a
//  measurement, and only the three rhythms this app dances to get a genre.
//
//  The measurement itself is bpmcore's and is verified by its own harness (see
//  Analysis/PROVENANCE.md), not from here — running it would need audio fixtures.
//

import XCTest
@testable import Pocket_Tandas

final class TrackAnalysisTests: XCTestCase {

    // MARK: - Tags beat measurements

    func testMeasurementShowsWhenNothingIsTagged() {
        var s = TrackMetadataSnapshot()
        s.estimatedBPM = 127.86
        s.estimatedGenre = "Tango"
        XCTAssertEqual(s.bpm, 128)          // rounded: a dancer taps whole numbers
        XCTAssertEqual(s.genre, "Tango")
        XCTAssertFalse(s.isEmpty)           // so the row gets its detail line
    }

    func testTagsWinOverMeasurements() {
        var s = TrackMetadataSnapshot(taggedGenre: "Vals", taggedBPM: 120)
        s.estimatedBPM = 127.86
        s.estimatedGenre = "Tango"
        XCTAssertEqual(s.bpm, 120)
        XCTAssertEqual(s.genre, "Vals")
    }

    func testBlankGenreTagDoesNotSuppressTheMeasurement() {
        var s = TrackMetadataSnapshot(taggedGenre: "")
        s.estimatedGenre = "Milonga"
        XCTAssertEqual(s.genre, "Milonga")
    }

    func testNothingKnownStaysNothing() {
        let s = TrackMetadataSnapshot()
        XCTAssertNil(s.bpm)
        XCTAssertNil(s.genre)
        XCTAssertTrue(s.isEmpty)
    }

    func testMeasurementReachesTheRow() {
        var s = TrackMetadataSnapshot(title: "Maragata", artist: "Aníbal Troilo")
        s.estimatedBPM = 127.86
        s.estimatedGenre = "Tango"
        XCTAssertEqual(TrackDisplay(metadata: s, fallback: "x").detailLine, "128 BPM · Tango")
    }

    // MARK: - Only tango, vals and milonga get a name

    func testDanceableRhythmsBecomeGenres() {
        XCTAssertEqual(AnalyzedRhythm.genre(for: .tango), "Tango")
        XCTAssertEqual(AnalyzedRhythm.genre(for: .vals), "Vals")
        XCTAssertEqual(AnalyzedRhythm.genre(for: .milonga), "Milonga")
    }

    func testEverythingElseIsLeftEmpty() {
        XCTAssertNil(AnalyzedRhythm.genre(for: .reggae))
        XCTAssertNil(AnalyzedRhythm.genre(for: .other))
    }

    // MARK: - What gets stored

    func testAResultWithNothingInItIsStillAnAnswer() {
        // A track the core could not measure records an empty row rather than
        // nothing at all, which is what stops it being decoded again every visit.
        XCTAssertTrue(TrackAnalysisResult().isEmpty)
        XCTAssertFalse(TrackAnalysisResult(bpm: 127.86).isEmpty)
        XCTAssertFalse(TrackAnalysisResult(genre: "Tango").isEmpty)
    }

    func testRowRoundTripsItsResult() {
        let result = TrackAnalysisResult(bpm: 127.86, genre: "Tango", confidence: 0.99)
        XCTAssertEqual(TrackAnalysis(trackKey: "k", result: result).result, result)
    }

    // MARK: - Threading

    func testTracksRunTwoCoresShortOfTheMachine() {
        XCTAssertEqual(TrackAnalysisQueue.concurrency,
                       max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        XCTAssertGreaterThanOrEqual(TrackAnalysisQueue.concurrency, 1)
    }
}
