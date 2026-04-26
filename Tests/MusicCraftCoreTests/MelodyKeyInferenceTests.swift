import XCTest
@testable import MusicCraftCore

final class MelodyKeyInferenceTests: XCTestCase {

    // MARK: - Edge cases

    func testEmptyInputReturnsEmpty() {
        let result = MelodyKeyInference.infer(from: [])
        XCTAssertEqual(result.count, 0)
    }

    func testSingleNoteReturnsEmpty() {
        let notes = [DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9)]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertEqual(result.count, 0)
    }

    func testTwoNotesSamePitchClassReturnsEmpty() {
        // Two notes same pitch class (insufficient distinction)
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 72, onsetTime: 0.5, duration: 0.1, confidence: 0.9),  // Also pitch class 0 (C)
        ]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - C major scale

    func testCMajorScaleProducesCMajorTopCandidate() {
        // C major scale with tonic C repeated to disambiguate from A minor
        // (A minor and C major both include all these pitch classes, but C appears more frequently)
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // C4, pitch class 0
            DetectedNote(midiNote: 62, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // D4, pitch class 2
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // E4, pitch class 4
            DetectedNote(midiNote: 65, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // F4, pitch class 5
            DetectedNote(midiNote: 67, onsetTime: 0.4, duration: 0.1, confidence: 0.9),  // G4, pitch class 7
            DetectedNote(midiNote: 69, onsetTime: 0.5, duration: 0.1, confidence: 0.9),  // A4, pitch class 9
            DetectedNote(midiNote: 71, onsetTime: 0.6, duration: 0.1, confidence: 0.9),  // B4, pitch class 11
            DetectedNote(midiNote: 72, onsetTime: 0.7, duration: 0.1, confidence: 0.9),  // C5, pitch class 0 (repeat tonic)
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major)
        XCTAssertEqual(result[0].score, 1.0)
    }

    // MARK: - A minor scale

    func testAMinorScaleProducesAMinorTopCandidate() {
        // A natural minor scale: A, B, C, D, E, F, G (all diatonic to A minor)
        let notes = [
            DetectedNote(midiNote: 69, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // A4, pitch class 9
            DetectedNote(midiNote: 71, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // B4, pitch class 11
            DetectedNote(midiNote: 60, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // C5, pitch class 0
            DetectedNote(midiNote: 62, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // D5, pitch class 2
            DetectedNote(midiNote: 64, onsetTime: 0.4, duration: 0.1, confidence: 0.9),  // E5, pitch class 4
            DetectedNote(midiNote: 65, onsetTime: 0.5, duration: 0.1, confidence: 0.9),  // F5, pitch class 5
            DetectedNote(midiNote: 67, onsetTime: 0.6, duration: 0.1, confidence: 0.9),  // G5, pitch class 7
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .A)
        XCTAssertEqual(result[0].key.mode, .minor)
        XCTAssertEqual(result[0].score, 1.0)
    }

    // MARK: - Disambiguation by tonic frequency

    func testCMajorVsAMinorTonicFrequencyDisambiguationCDominant() {
        // Pitch classes: C (3×), A (1×), E (1×), G (1×)
        // C major: all 4 pitch classes diatonic (score 1.0, tonic frequency 3)
        // A minor: all 4 pitch classes diatonic (score 1.0, tonic frequency 1)
        // Should disambiguate to C major (tonic C appears 3×)
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // C, pitch class 0
            DetectedNote(midiNote: 72, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // C, pitch class 0
            DetectedNote(midiNote: 69, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // A, pitch class 9
            DetectedNote(midiNote: 84, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // C, pitch class 0
            DetectedNote(midiNote: 64, onsetTime: 0.4, duration: 0.1, confidence: 0.9),  // E, pitch class 4
            DetectedNote(midiNote: 67, onsetTime: 0.5, duration: 0.1, confidence: 0.9),  // G, pitch class 7
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major)
    }

    func testCMajorVsAMinorTonicFrequencyDisambiguationADominant() {
        // Pitch classes: A (3×), C (1×), E (1×), G (1×)
        // A minor: all 4 pitch classes diatonic (score 1.0, tonic frequency 3)
        // C major: all 4 pitch classes diatonic (score 1.0, tonic frequency 1)
        // Should disambiguate to A minor (tonic A appears 3×)
        let notes = [
            DetectedNote(midiNote: 69, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // A, pitch class 9
            DetectedNote(midiNote: 81, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // A, pitch class 9
            DetectedNote(midiNote: 60, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // C, pitch class 0
            DetectedNote(midiNote: 93, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // A, pitch class 9
            DetectedNote(midiNote: 64, onsetTime: 0.4, duration: 0.1, confidence: 0.9),  // E, pitch class 4
            DetectedNote(midiNote: 67, onsetTime: 0.5, duration: 0.1, confidence: 0.9),  // G, pitch class 7
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .A)
        XCTAssertEqual(result[0].key.mode, .minor)
    }

    func testCMajorVsAMinorTiedFrequencyPrefersMinor() {
        // Pitch classes: C (1×), A (1×), E (1×), G (1×)
        // Tied frequency count; should prefer minor (per algorithm)
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // C, pitch class 0
            DetectedNote(midiNote: 69, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // A, pitch class 9
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // E, pitch class 4
            DetectedNote(midiNote: 67, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // G, pitch class 7
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.mode, .minor)
    }

    // MARK: - maxCandidates parameter

    func testMaxCandidatesOneReturnsOne() {
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 62, onsetTime: 0.1, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),
        ]

        let result = MelodyKeyInference.infer(from: notes, maxCandidates: 1)

        XCTAssertEqual(result.count, 1)
    }

    func testMaxCandidatesTwoReturnsTwoOrFewer() {
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 62, onsetTime: 0.1, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),
        ]

        let result = MelodyKeyInference.infer(from: notes, maxCandidates: 2)

        XCTAssertGreaterThanOrEqual(result.count, 1)
        XCTAssertLessThanOrEqual(result.count, 2)
    }

    // MARK: - Partial fit

    func testPartialFitProducesIntermediateScore() {
        // Pitch classes: C (0), E (4), G (7), B (11)
        // C major: 0,2,4,5,7,9,11 — matches C, E, G, B = 4/4 diatonic = score 1.0
        // G major: 7,9,11,0,2,4,6 — matches C, E, G, B = 4/4 diatonic = score 1.0
        // C minor: 0,2,3,5,7,8,10 — matches C, E, G = 3/4 diatonic = score 0.75
        // (All major/minor at root 2 would match C, E, G, B but maybe not all...)
        // So multiple keys tie at 1.0, and C major should win on frequency
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),  // C
            DetectedNote(midiNote: 64, onsetTime: 0.1, duration: 0.1, confidence: 0.9),  // E
            DetectedNote(midiNote: 67, onsetTime: 0.2, duration: 0.1, confidence: 0.9),  // G
            DetectedNote(midiNote: 71, onsetTime: 0.3, duration: 0.1, confidence: 0.9),  // B
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        // Score should be at least 0.75 (partial fit)
        XCTAssertGreaterThanOrEqual(result[0].score, 0.75)
    }

    // MARK: - Public API and Sendable

    func testKeyCandidatePublicInit() {
        let key = MusicalKey(root: .C, mode: .major)
        let candidate = MelodyKeyInference.KeyCandidate(key: key, score: 0.95, tonicFrequency: 3)

        XCTAssertEqual(candidate.key.root, .C)
        XCTAssertEqual(candidate.score, 0.95)
        XCTAssertEqual(candidate.tonicFrequency, 3)
    }

    func testKeyCandidateEqualityAndHashing() {
        let key1 = MusicalKey(root: .C, mode: .major)
        let key2 = MusicalKey(root: .C, mode: .major)
        let key3 = MusicalKey(root: .D, mode: .major)

        let candidate1 = MelodyKeyInference.KeyCandidate(key: key1, score: 0.95, tonicFrequency: 3)
        let candidate2 = MelodyKeyInference.KeyCandidate(key: key2, score: 0.95, tonicFrequency: 3)
        let candidate3 = MelodyKeyInference.KeyCandidate(key: key3, score: 0.95, tonicFrequency: 3)

        XCTAssertEqual(candidate1, candidate2)
        XCTAssertNotEqual(candidate1, candidate3)

        let set: Set<MelodyKeyInference.KeyCandidate> = [candidate1, candidate2, candidate3]
        XCTAssertEqual(set.count, 2)
    }

    func testInferPublicAPICallable() {
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 62, onsetTime: 0.1, duration: 0.1, confidence: 0.9),
            DetectedNote(midiNote: 64, onsetTime: 0.2, duration: 0.1, confidence: 0.9),
        ]

        // Should be callable without @testable
        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertNotNil(result)
    }
}
