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
        // 0.0.12: score is now a tonal-profile correlation (0–1), not the old diatonic fraction.
        XCTAssertGreaterThan(result[0].score, 0.0)
        XCTAssertLessThanOrEqual(result[0].score, 1.0)
    }

    // MARK: - A minor scale (tonic emphasized by duration)

    func testAMinorScaleProducesAMinorTopCandidate() {
        // A minor, with the tonic triad (A, C, E) emphasized by duration so the tonal profile
        // resolves to minor rather than its relative major. (An equal-duration scale with the
        // tonic sounded only once is genuinely ambiguous between A minor and C major — that's
        // what duration weighting is for.)
        let notes = [
            DetectedNote(midiNote: 69, onsetTime: 0.0, duration: 1.0, confidence: 0.9),  // A — long tonic
            DetectedNote(midiNote: 71, onsetTime: 1.0, duration: 0.1, confidence: 0.9),  // B passing
            DetectedNote(midiNote: 60, onsetTime: 1.1, duration: 0.5, confidence: 0.9),  // C — held (minor 3rd)
            DetectedNote(midiNote: 62, onsetTime: 1.6, duration: 0.1, confidence: 0.9),  // D passing
            DetectedNote(midiNote: 64, onsetTime: 1.7, duration: 0.5, confidence: 0.9),  // E — held (5th)
            DetectedNote(midiNote: 65, onsetTime: 2.2, duration: 0.1, confidence: 0.9),  // F passing
            DetectedNote(midiNote: 67, onsetTime: 2.3, duration: 0.1, confidence: 0.9),  // G passing
            DetectedNote(midiNote: 69, onsetTime: 2.4, duration: 1.0, confidence: 0.9),  // A — long tonic (return)
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .A)
        XCTAssertEqual(result[0].key.mode, .minor)
        XCTAssertGreaterThan(result[0].score, 0.0)
        XCTAssertLessThanOrEqual(result[0].score, 1.0)
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

    func testMajorTriadContentResolvesToMajorNotRelativeMinor() {
        // Regression for the removed minor bias. C–E–G (the C major triad) is diatonic to both
        // C major and A/E minor; the pre-0.0.12 algorithm tied them and broke the tie by
        // hard-preferring minor. Tonal-profile correlation now picks C MAJOR — the chord's
        // actual tonal center — instead of defaulting to a relative/parallel minor.
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.4, confidence: 0.9),  // C
            DetectedNote(midiNote: 64, onsetTime: 0.4, duration: 0.4, confidence: 0.9),  // E
            DetectedNote(midiNote: 67, onsetTime: 0.8, duration: 0.4, confidence: 0.9),  // G
            DetectedNote(midiNote: 72, onsetTime: 1.2, duration: 0.4, confidence: 0.9),  // C (octave)
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major, "major-triad content must not default to minor")
    }

    // MARK: - Duration emphasis decides the relative pair (0.0.12 capability)

    func testDurationEmphasisOnTonicTriadResolvesMajor() {
        // Same C-major scale pitch-class content; the C-major triad (C, E, G) is held long.
        // The tonal profile must resolve to C major.
        let long = 0.8, short = 0.12
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: long, confidence: 0.9),  // C *
            DetectedNote(midiNote: 62, onsetTime: 0.9, duration: short, confidence: 0.9), // D
            DetectedNote(midiNote: 64, onsetTime: 1.1, duration: long, confidence: 0.9),  // E *
            DetectedNote(midiNote: 65, onsetTime: 2.0, duration: short, confidence: 0.9), // F
            DetectedNote(midiNote: 67, onsetTime: 2.2, duration: long, confidence: 0.9),  // G *
            DetectedNote(midiNote: 69, onsetTime: 3.1, duration: short, confidence: 0.9), // A
            DetectedNote(midiNote: 71, onsetTime: 3.3, duration: short, confidence: 0.9), // B
        ]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .C)
        XCTAssertEqual(result[0].key.mode, .major)
    }

    func testDurationEmphasisOnTonicTriadResolvesMinor() {
        // SAME pitch-class content as above, but the A-minor triad (A, C, E) is held long.
        // Duration emphasis flips the call to A minor — proving the relative pair is decided
        // by tonal weight, not a fixed mode preference.
        let long = 0.8, short = 0.12
        let notes = [
            DetectedNote(midiNote: 69, onsetTime: 0.0, duration: long, confidence: 0.9),  // A *
            DetectedNote(midiNote: 71, onsetTime: 0.9, duration: short, confidence: 0.9), // B
            DetectedNote(midiNote: 60, onsetTime: 1.1, duration: long, confidence: 0.9),  // C *
            DetectedNote(midiNote: 62, onsetTime: 2.0, duration: short, confidence: 0.9), // D
            DetectedNote(midiNote: 64, onsetTime: 2.2, duration: long, confidence: 0.9),  // E *
            DetectedNote(midiNote: 65, onsetTime: 3.1, duration: short, confidence: 0.9), // F
            DetectedNote(midiNote: 67, onsetTime: 3.3, duration: short, confidence: 0.9), // G
        ]
        let result = MelodyKeyInference.infer(from: notes)
        XCTAssertGreaterThan(result.count, 0)
        XCTAssertEqual(result[0].key.root, .A)
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

    // MARK: - Score semantics (0.0.12: 0–1 tonal-profile correlation)

    func testScoreIsZeroToOneConfidence() {
        // 0.0.12: KeyCandidate.score is the winning KK-profile correlation, clamped to [0, 1].
        // (Was the diatonic fraction pre-0.0.12; consumers gating on the old scale must recalibrate.)
        let notes = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.4, confidence: 0.9),  // C
            DetectedNote(midiNote: 64, onsetTime: 0.4, duration: 0.4, confidence: 0.9),  // E
            DetectedNote(midiNote: 67, onsetTime: 0.8, duration: 0.4, confidence: 0.9),  // G
            DetectedNote(midiNote: 71, onsetTime: 1.2, duration: 0.2, confidence: 0.9),  // B
        ]

        let result = MelodyKeyInference.infer(from: notes)

        XCTAssertGreaterThan(result.count, 0)
        XCTAssertGreaterThan(result[0].score, 0.0)
        XCTAssertLessThanOrEqual(result[0].score, 1.0)
        // ranked: top candidate's score is the best correlation
        if result.count >= 2 { XCTAssertGreaterThanOrEqual(result[0].score, result[1].score) }
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
