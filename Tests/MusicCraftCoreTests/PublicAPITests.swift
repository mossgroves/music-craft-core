import XCTest
import MusicCraftCore

/// Tests that exercise the public API surface without @testable import.
/// These tests verify that types are correctly exposed as public and can be consumed from external packages.
///
/// As of 0.1.0 the hand-rolled DSP chord path was removed (PitchDetector, ChromaExtractor,
/// CanonicalChromaLibrary / ChromaTemplateLibrary, ChordDetector, IntervalDetector,
/// ChordClassifierProvider, OnsetDetector, NoiseBaseline, NoiseCalibrator), so their public-API
/// regression tests were removed with them. The surviving public surface below — DSPUtilities,
/// the music-theory types, ProgressionAnalyzer, the contour/note types, and MelodyKeyInference —
/// remains in active use by the Basic Pitch + note-native pipeline.
final class PublicAPITests: XCTestCase {

    // MARK: - DSPUtilities Public API

    func testDSPUtilitiesHannWindow() {
        let window = DSPUtilities.hannWindow(length: 8192)
        XCTAssertEqual(window.count, 8192)
        // Edges should taper to near 0
        XCTAssertLessThan(abs(Double(window[0])), 0.001)
        XCTAssertLessThan(abs(Double(window[8191])), 0.001)
    }

    func testDSPUtilitiesBlackmanWindow() {
        let window = DSPUtilities.blackmanWindow(length: 8192)
        XCTAssertEqual(window.count, 8192)
        // Edges should taper to near 0
        XCTAssertLessThan(abs(Double(window[0])), 0.001)
        XCTAssertLessThan(abs(Double(window[8191])), 0.001)
    }

    func testDSPUtilitiesLog2Ceil() {
        XCTAssertEqual(DSPUtilities.log2Ceil(1024), 10)
        XCTAssertEqual(DSPUtilities.log2Ceil(2048), 11)
        XCTAssertEqual(DSPUtilities.log2Ceil(2049), 12)
    }

    // MARK: - RomanNumeral Public API

    func testRomanNumeralPublicInit() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        XCTAssertEqual(roman.degree, .five)
        XCTAssertEqual(roman.accidental, .natural)
        XCTAssertEqual(roman.quality, .major)
        XCTAssertEqual(roman.displayString, "V")
    }

    // MARK: - SongReference Public API

    func testSongReferencePublicInit() {
        let reference = SongReference(songTitle: "Let It Be", artist: "The Beatles", detail: "1970")
        XCTAssertEqual(reference.songTitle, "Let It Be")
        XCTAssertEqual(reference.artist, "The Beatles")
        XCTAssertEqual(reference.detail, "1970")
    }

    // MARK: - ProgressionPattern Public API

    func testProgressionPatternPublicInit() {
        let numerals = [
            RomanNumeral(degree: .one, quality: .major),
            RomanNumeral(degree: .five, quality: .major),
        ]
        let examples = [SongReference(songTitle: "Test Song", artist: "Test Artist", detail: "2026")]
        let pattern = ProgressionPattern(name: "Test Pattern", numerals: numerals, description: "A test pattern", songExamples: examples)

        XCTAssertEqual(pattern.name, "Test Pattern")
        XCTAssertEqual(pattern.numerals.count, 2)
        XCTAssertEqual(pattern.description, "A test pattern")
        XCTAssertEqual(pattern.songExamples.count, 1)
    }

    // MARK: - RecognizedPattern Public API

    func testRecognizedPatternPublicAccess() {
        let numerals = [RomanNumeral(degree: .one, quality: .major)]
        let examples = [SongReference(songTitle: "Test", artist: "Test", detail: "2026")]
        let pattern = ProgressionPattern(name: "Test", numerals: numerals, description: "Test", songExamples: examples)
        let recognized = RecognizedPattern(pattern: pattern, matchType: .exact)

        XCTAssertEqual(recognized.name, "Test")
        XCTAssertEqual(recognized.description, "Test")
        XCTAssertEqual(recognized.songExamples.count, 1)
        XCTAssertEqual(recognized.matchType, .exact)
        XCTAssertEqual(recognized.displayString, "I")
    }

    // MARK: - ProgressionAnalyzer Public API

    func testProgressionAnalyzerInferKeyPublic() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)

        XCTAssertNotNil(key)
        XCTAssertEqual(key?.root, .C)
        XCTAssertEqual(key?.mode, .major)
    }

    func testProgressionAnalyzerRecognizePatternPublic() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Pop Anthem")
        XCTAssertEqual(result?.matchType, .exact)
    }

    // MARK: - ContourNote Public API (0.0.8)

    func testContourNotePublicConstruction() {
        let note = ContourNote(
            pitchSemitoneStep: 2,
            parsonsCode: .up,
            onsetTime: 0.5,
            duration: 0.4
        )

        XCTAssertNotNil(note)
        XCTAssertEqual(note.pitchSemitoneStep, 2)
    }

    func testParsonsCodePublic() {
        let code = ParsonsCode.up
        XCTAssertEqual(code.rawValue, "*")
    }

    // MARK: - DetectedNote Public API (0.0.8)

    func testDetectedNotePublicConstruction() {
        let note = DetectedNote(
            midiNote: 60,
            onsetTime: 0.5,
            duration: 0.4,
            confidence: 0.9
        )

        XCTAssertNotNil(note)
        XCTAssertEqual(note.midiNote, 60)
        XCTAssertEqual(note.pitchClass, 0)
    }

    // MARK: - MelodyKeyInference Public API (0.0.8)

    func testMelodyKeyInferencePublicAPI() {
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 62, onsetTime: 0.1, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),
        ]

        let candidates = MelodyKeyInference.infer(from: notes)

        XCTAssertNotNil(candidates)
    }

    func testMelodyKeyInferenceKeyCandidatePublic() {
        let key = MusicalKey(root: .C, mode: .major)
        let candidate = MelodyKeyInference.KeyCandidate(key: key, score: 0.95, tonicFrequency: 3)

        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate.score, 0.95)
    }
}
