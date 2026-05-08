import XCTest
@testable import MusicCraftCore

final class VoicingLibraryTests: XCTestCase {
    func testVoicingsForCMajor() {
        let chord = Chord(root: .C, quality: .major)
        let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard)

        XCTAssertGreaterThan(voicings.count, 0)
        XCTAssertLessThanOrEqual(voicings.count, 5)

        for voicing in voicings {
            XCTAssertEqual(voicing.chord, chord)
            XCTAssertEqual(voicing.tuning, GuitarTuning.standard)
        }
    }

    func testVoicingsForAMinor() {
        let chord = Chord(root: .A, quality: .minor)
        let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard)

        XCTAssertGreaterThan(voicings.count, 0)
    }

    func testVoicingsRespectLimit() {
        let chord = Chord(root: .D, quality: .major)
        let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard, limit: 2)

        XCTAssertLessThanOrEqual(voicings.count, 2)
    }

    func testNonStandardTuningReturnsEmpty() {
        let chord = Chord(root: .C, quality: .major)
        let voicings = VoicingLibrary.voicings(for: chord, tuning: .dropD)

        XCTAssertEqual(voicings.count, 0)
    }

    func testUnknownChordReturnsEmpty() {
        // A chord quality not in our curated set
        let chord = Chord(root: .C, quality: .diminished)
        let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard)

        XCTAssertEqual(voicings.count, 0)
    }

    func testChordLookupsAreDeterministic() {
        let chord = Chord(root: .G, quality: .major)
        let voicings1 = VoicingLibrary.voicings(for: chord, tuning: .standard)
        let voicings2 = VoicingLibrary.voicings(for: chord, tuning: .standard)

        XCTAssertEqual(voicings1.count, voicings2.count)
        for (v1, v2) in zip(voicings1, voicings2) {
            XCTAssertEqual(v1.position, v2.position)
        }
    }

    func testCommonChordsHaveVoicings() {
        let commonChords = [
            (NoteName.C, ChordQuality.major),
            (NoteName.G, ChordQuality.major),
            (NoteName.D, ChordQuality.major),
            (NoteName.A, ChordQuality.minor),
            (NoteName.E, ChordQuality.minor),
        ]

        for (root, quality) in commonChords {
            let chord = Chord(root: root, quality: quality)
            let voicings = VoicingLibrary.voicings(for: chord, tuning: .standard)
            XCTAssertGreaterThan(voicings.count, 0, "Expected voicings for \(chord.displayName)")
        }
    }
}
