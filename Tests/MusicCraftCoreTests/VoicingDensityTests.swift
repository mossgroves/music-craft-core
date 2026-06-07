import XCTest
@testable import MusicCraftCore

/// `AudioExtractor.voicingDensity(of:)` — the take-type measure: mean number of simultaneously-sounding
/// DISTINCT pitch classes over the take's sounding time. Deterministic by construction; synthetic
/// `[TranscribedNote]` (no model run).
final class VoicingDensityTests: XCTestCase {
    private let acc = 1e-9

    private func note(_ midi: Int, _ onset: Double, _ duration: Double) -> TranscribedNote {
        TranscribedNote(pitchMIDI: midi, onsetTime: onset, duration: duration, velocity: 0.8, pitchBend: nil)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(AudioExtractor.voicingDensity(of: []), 0.0, accuracy: acc)
    }

    func testOneNoteIsOne() {
        XCTAssertEqual(AudioExtractor.voicingDensity(of: [note(60, 0, 1)]), 1.0, accuracy: acc)
    }

    func testSequentialDistinctPitchesIsOne() {
        // Two back-to-back notes, different pitch classes, never simultaneous → 1.0.
        let notes = [note(60, 0, 1), note(64, 1, 1)]   // C then E
        XCTAssertEqual(AudioExtractor.voicingDensity(of: notes), 1.0, accuracy: acc)
    }

    func testStruckTriadIsThree() {
        // Three fully-overlapping notes, distinct pitch classes (a struck triad) → 3.0.
        let notes = [note(60, 0, 1), note(64, 0, 1), note(67, 0, 1)]   // C E G
        XCTAssertEqual(AudioExtractor.voicingDensity(of: notes), 3.0, accuracy: acc)
    }

    func testOctaveDoublingCountsAsOnePitchClass() {
        // Two fully-overlapping notes of the SAME pitch class (octave/unison) → 1.0
        // (distinct pitch classes, not raw note count — so doublings/overtones don't inflate it).
        let notes = [note(60, 0, 1), note(72, 0, 1)]   // C and C an octave up → pc 0, 0
        XCTAssertEqual(AudioExtractor.voicingDensity(of: notes), 1.0, accuracy: acc)
    }

    func testHalfOverlapIsBetweenOneAndTwo() {
        // C [0,1), E [0.5,1.5): slices [0,0.5)=1pc, [0.5,1)=2pc, [1,1.5)=1pc, each 0.5s long.
        // weighted = 0.5·1 + 0.5·2 + 0.5·1 = 2.0; covered = 1.5 → 2.0/1.5 = 4/3 ≈ 1.333.
        let notes = [note(60, 0, 1), note(64, 0.5, 1)]
        let d = AudioExtractor.voicingDensity(of: notes)
        XCTAssertEqual(d, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertGreaterThan(d, 1.0)
        XCTAssertLessThan(d, 2.0)
    }

    func testDeterministicSameInputSameOutput() {
        let notes = [note(60, 0, 1), note(64, 0.5, 1), note(67, 0.25, 0.8), note(72, 0, 1)]
        XCTAssertEqual(AudioExtractor.voicingDensity(of: notes),
                       AudioExtractor.voicingDensity(of: notes), accuracy: 0)
    }
}
