// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  TrackAnalysisTests.swift
//  Pocket TandasTests
//
//  Covers the three rules the measuring pass answers to: a tag always beats a
//  measurement, only the three rhythms this app dances to get a genre, and a
//  value that was measured rather than read is marked as such in the row.
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

    // MARK: - Measured values are marked in the row

    func testMeasuredFieldsAreMarkedAndTaggedOnesAreNot() {
        var s = TrackMetadataSnapshot(title: "Maragata", dateText: "1941")
        s.estimatedBPM = 127.86
        s.estimatedGenre = "Tango"
        let parts = TrackDisplay(metadata: s, fallback: "x").detailParts
        XCTAssertEqual(parts.map(\.text), ["128 BPM", "Tango", "1941"])
        // The date is a tag like any other; only the two measured fields carry it.
        XCTAssertEqual(parts.map(\.isEstimated), [true, true, false])
    }

    func testATaggedFieldBesideAMeasuredOneStaysUnmarked() {
        var s = TrackMetadataSnapshot(taggedBPM: 132)
        s.estimatedBPM = 127.86      // never shown: the tag wins
        s.estimatedGenre = "Milonga"
        let parts = TrackDisplay(metadata: s, fallback: "x").detailParts
        XCTAssertEqual(parts.map(\.text), ["132 BPM", "Milonga"])
        XCTAssertEqual(parts.map(\.isEstimated), [false, true])
    }

    func testABlankGenreTagLeavesTheMeasurementMarked() {
        var s = TrackMetadataSnapshot(taggedGenre: "")
        s.estimatedGenre = "Milonga"
        XCTAssertTrue(s.isGenreEstimated)
    }

    func testNothingKnownMarksNothing() {
        let s = TrackMetadataSnapshot()
        XCTAssertFalse(s.isBPMEstimated)
        XCTAssertFalse(s.isGenreEstimated)
        XCTAssertTrue(TrackDisplay(metadata: s, fallback: "x").detailParts.isEmpty)
    }

    func testAMirroredRowHasNothingToMark() {
        // Remote Send resolves the line on the sending device and only the text
        // crosses the wire, so the mirror cannot know which half was measured.
        XCTAssertEqual(TrackDisplay.DetailPart.opaque("128 BPM · Tango"),
                       [TrackDisplay.DetailPart(text: "128 BPM · Tango", isEstimated: false)])
        XCTAssertTrue(TrackDisplay.DetailPart.opaque(nil).isEmpty)
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
