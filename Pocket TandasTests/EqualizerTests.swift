// Pocket Tandas
// Copyright (C) 2026 Mykola Shaforostov
// SPDX-License-Identifier: GPL-3.0-or-later
// Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
//
//  EqualizerTests.swift
//  Pocket TandasTests
//
//  The parts of the EQ that are arithmetic rather than sound: the Q ↔ octaves
//  conversion the panel shows, the response curve the panel draws, the band table
//  each preset loads, and what survives a relaunch.
//
//  The curve is checked against closed forms rather than against AVAudioUnitEQ —
//  the unit exposes no response to compare with, which is why EQCurve exists.
//

import XCTest
@testable import Pocket_Tandas

final class EqualizerTests: XCTestCase {

    /// Duplicated from Equalizer, where it is private. If it changes there and not
    /// here, these tests start writing to a key nothing reads and will say so by
    /// failing the persistence cases.
    private let defaultsKey = "equalizer.settings.v2"
    private let rate: Double = 44100

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    // MARK: - Q ↔ octaves

    func testQRoundTripsThroughOctaves() {
        for q in stride(from: 0.4, through: 14.0, by: 0.2) {
            let octaves = EQBandwidth.octaves(forQ: Float(q))
            XCTAssertEqual(EQBandwidth.q(forOctaves: octaves), Float(q), accuracy: 0.001,
                           "Q \(q) did not survive the trip through octaves")
        }
    }

    func testQMatchesTheKnownOctaveWidths() {
        // The textbook pairs: one octave is Q ≈ 1.414, two octaves Q ≈ 0.667.
        XCTAssertEqual(EQBandwidth.q(forOctaves: 1.0), 1.4142, accuracy: 0.001)
        XCTAssertEqual(EQBandwidth.q(forOctaves: 2.0), 0.6667, accuracy: 0.001)
        // ...and higher Q is a narrower band, which is what the slider promises.
        XCTAssertLessThan(EQBandwidth.octaves(forQ: 4), EQBandwidth.octaves(forQ: 1))
    }

    // MARK: - One band's response

    func testFlatBandIsTransparent() {
        let band = peak(gain: 0)
        for hz in [20.0, 100, 1000, 6000, 18000] {
            XCTAssertEqual(EQCurve.magnitude(of: band, at: hz, sampleRate: rate), 0,
                           accuracy: 0.0001)
        }
    }

    func testPeakReachesItsGainAtItsCentre() {
        XCTAssertEqual(EQCurve.magnitude(of: peak(gain: 12), at: 1000, sampleRate: rate),
                       12, accuracy: 0.01)
        XCTAssertEqual(EQCurve.magnitude(of: peak(gain: -8), at: 1000, sampleRate: rate),
                       -8, accuracy: 0.01)
    }

    func testPeakIsNarrowerAtHigherQ() {
        let wide = peak(gain: 12, q: 0.5)
        let narrow = peak(gain: 12, q: 6)
        XCTAssertGreaterThan(EQCurve.magnitude(of: wide, at: 2000, sampleRate: rate),
                             EQCurve.magnitude(of: narrow, at: 2000, sampleRate: rate))
    }

    func testButterworthPassesAreDownThreeDecibelsAtTheirCorner() {
        let lowCut = EQBand(id: 0, name: "Low Cut", kind: .highPass, frequency: 100,
                            frequencyRange: 20...120)
        let highCut = EQBand(id: 1, name: "High Cut", kind: .lowPass, frequency: 10000,
                             frequencyRange: 5000...20000)
        XCTAssertEqual(EQCurve.magnitude(of: lowCut, at: 100, sampleRate: rate),
                       -3.0103, accuracy: 0.01)
        XCTAssertEqual(EQCurve.magnitude(of: highCut, at: 10000, sampleRate: rate),
                       -3.0103, accuracy: 0.01)
        // 12 dB per octave: two octaves below the corner is 24 dB down.
        XCTAssertEqual(EQCurve.magnitude(of: lowCut, at: 25, sampleRate: rate),
                       -24.10, accuracy: 0.05)
    }

    func testShelvesReachHalfTheirGainAtTheCorner() {
        let bass = EQBand(id: 1, name: "Bass", kind: .lowShelf, frequency: 100,
                          gain: 12, frequencyRange: 40...300)
        let hiss = EQBand(id: 4, name: "Hiss Cut", kind: .highShelf, frequency: 7500,
                          gain: -12, frequencyRange: 4000...12000)
        XCTAssertEqual(EQCurve.magnitude(of: bass, at: 100, sampleRate: rate),
                       6, accuracy: 0.01)
        XCTAssertEqual(EQCurve.magnitude(of: hiss, at: 7500, sampleRate: rate),
                       -6, accuracy: 0.01)
        // Well inside the shelf it reaches the whole gain.
        XCTAssertEqual(EQCurve.magnitude(of: bass, at: 20, sampleRate: rate),
                       12, accuracy: 0.1)
    }

    func testASwitchedOutCutContributesNothing() {
        var highCut = EQBand(id: 5, name: "High Cut", kind: .lowPass, frequency: 10000,
                             isEnabled: false, frequencyRange: 5000...20000)
        XCTAssertEqual(EQCurve.magnitude(of: highCut, at: 16000, sampleRate: rate), 0)
        highCut.isEnabled = true
        XCTAssertLessThan(EQCurve.magnitude(of: highCut, at: 16000, sampleRate: rate), -10)
    }

    // MARK: - The whole unit

    func testGoldenAgePresetDrawsTheArticlesCurve() {
        let response = EQCurve.response(of: Equalizer.bands(for: .goldenAge),
                                        sampleRate: rate, count: 2048)
        // Bass scissors: rolled off at 20 Hz, peaking around 50, home by 250.
        XCTAssertEqual(dB(response, at: 50), 5.10, accuracy: 0.2)
        XCTAssertEqual(dB(response, at: 250), 0.17, accuracy: 0.2)
        XCTAssertLessThan(dB(response, at: 20), dB(response, at: 50))
        // Brilliance up, then the hiss and artifact scissors.
        XCTAssertEqual(dB(response, at: 6000), 4.07, accuracy: 0.2)
        XCTAssertEqual(dB(response, at: 10000), -5.89, accuracy: 0.3)
        XCTAssertEqual(dB(response, at: 16000), -21.85, accuracy: 0.5)
        // The reverb control is left at zero: the article is emphatic that it is
        // only for records that actually have reverb to cut.
        XCTAssertEqual(dB(response, at: 1000), 0.15, accuracy: 0.2)
    }

    func testFlatPresetIsAudiblyFlat() {
        let response = EQCurve.response(of: Equalizer.bands(for: .flat),
                                        sampleRate: rate, count: 512)
        // Only the ultra-low rail is in circuit, and it is out of the way by 60 Hz.
        for hz in [60.0, 200, 1000, 8000, 18000] {
            XCTAssertEqual(dB(response, at: hz), 0, accuracy: 0.35, "at \(hz) Hz")
        }
        XCTAssertLessThan(dB(response, at: 20), -1)
    }

    func testPost1950MovesBrillianceUpAndLeavesEverythingElseAlone() {
        let bands = Equalizer.bands(for: .post1950)
        XCTAssertEqual(bands[3].frequency, 11000)
        XCTAssertFalse(bands[5].isEnabled, "the artifact rail takes the music with it on vinyl")
        XCTAssertTrue(bands.filter(\.kind.hasGain).allSatisfy { $0.gain == 0 })
    }

    // MARK: - What counts as "the EQ is doing something"

    func testTheRailsDoNotBadgeTheButtonButTheirMovesDo() {
        let eq = Equalizer()
        eq.apply(.flat)
        XCTAssertFalse(eq.isActive, "a default low cut is a safety rail, not colour")
        XCTAssertTrue(eq.bands[0].isInCircuit, "...but it is still filtering")

        eq.setFrequency(90, bandID: 0)
        XCTAssertTrue(eq.isActive)

        eq.apply(.flat)
        eq.setBandEnabled(true, bandID: 5)
        XCTAssertTrue(eq.isActive, "a high cut is only ever switched in on purpose")

        eq.apply(.flat)
        eq.setGain(3, bandID: 1)
        XCTAssertTrue(eq.isActive)
    }

    func testKindsExposeOnlyTheirOwnKnobs() {
        let eq = Equalizer()
        eq.apply(.flat)
        // A gain on a cut filter, or a Q on a shelf, is not a thing.
        eq.setGain(9, bandID: 0)
        XCTAssertEqual(eq.bands[0].gain, 0)
        let bassWidth = eq.bands[1].bandwidth
        eq.setBandwidth(0.5, bandID: 1)
        XCTAssertEqual(eq.bands[1].bandwidth, bassWidth)
        // ...and a switch on a gain band leaves it in circuit.
        eq.setBandEnabled(false, bandID: 1)
        XCTAssertTrue(eq.bands[1].isEnabled)
    }

    // MARK: - Persistence

    func testSettingsSurviveARelaunch() {
        let first = Equalizer()
        first.apply(.goldenAge)
        first.setFrequency(45, bandID: 0)
        first.setBandwidth(EQBandwidth.octaves(forQ: 3.5), bandID: 2)
        first.setGain(-4.5, bandID: 2)
        first.setEnabled(false)

        let second = Equalizer()
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(second.bands.count, 6)
        XCTAssertEqual(second.bands[0].frequency, 45, accuracy: 0.001)
        XCTAssertEqual(second.bands[2].q, 3.5, accuracy: 0.01)
        XCTAssertEqual(second.bands[2].gain, -4.5, accuracy: 0.001)
        XCTAssertTrue(second.bands[5].isEnabled, "Golden Age switches the artifact rail in")
    }

    func testAThreeBandBlobIsIgnoredRatherThanHalfApplied() {
        // What a v1 snapshot looked like, in case one ever lands under the v2 key.
        let legacy = """
            {"isEnabled":true,"bands":[{"frequency":120,"bandwidth":1.5,"gain":6},\
            {"frequency":1000,"bandwidth":1,"gain":-3},\
            {"frequency":6000,"bandwidth":1.5,"gain":4}]}
            """
        UserDefaults.standard.set(Data(legacy.utf8), forKey: defaultsKey)

        let eq = Equalizer()
        XCTAssertEqual(eq.bands.count, 6)
        XCTAssertEqual(eq.bands.map(\.frequency), Equalizer.defaultBands().map(\.frequency))
        XCTAssertTrue(eq.bands.filter(\.kind.hasGain).allSatisfy { $0.gain == 0 })
    }

    // MARK: - The wire payload

    func testABandFromAnOlderPeerDecodesAsAPlainPeak() throws {
        // No kind, no caption, no isEnabled — a band as the three-band build sent it.
        let old = """
            {"id":1,"name":"Mid","frequency":1000,"bandwidth":1,"gain":-3,\
            "minFrequency":100,"maxFrequency":8000}
            """
        let band = try JSONDecoder().decode(EQBand.self, from: Data(old.utf8))
        XCTAssertEqual(band.kind, .peak)
        XCTAssertTrue(band.isEnabled)
        XCTAssertEqual(band.caption, "")
        XCTAssertEqual(band.gain, -3)
        XCTAssertTrue(band.kind.hasGain)
        XCTAssertTrue(band.kind.hasQ)
    }

    func testABandRoundTripsThroughJSON() throws {
        let original = Equalizer.bands(for: .goldenAge)
        let copy = try JSONDecoder().decode([EQBand].self,
                                            from: JSONEncoder().encode(original))
        XCTAssertEqual(copy, original)
    }

    // MARK: - Helpers

    private func peak(gain: Float, q: Float = 1.0) -> EQBand {
        EQBand(id: 2, name: "Reverb Cut", kind: .peak, frequency: 1000,
               bandwidth: EQBandwidth.octaves(forQ: q), gain: gain,
               frequencyRange: 300...3000)
    }

    /// Read the plotted grid at a frequency, the way the curve view does.
    private func dB(_ response: [Double], at hz: Double) -> Double {
        let position = EQCurve.position(of: hz) * Double(response.count - 1)
        let low = min(max(Int(position), 0), response.count - 1)
        let high = min(low + 1, response.count - 1)
        let t = position - Double(low)
        return response[low] * (1 - t) + response[high] * t
    }
}
