import XCTest
@testable import MusicCraftCore

final class ProgressionAnalyzerTests: XCTestCase {

    // MARK: - InferKey Tests

    func testInferKeyCMajor() {
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

    func testInferKeyAMinor() {
        let chords = [
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.root, .A)
        XCTAssertEqual(key?.mode, .minor)
    }

    func testInferKeyFirstChordBias() {
        let chords = [
            Chord(root: .A, quality: .minor),
            Chord(root: .A, quality: .minor),
            Chord(root: .E, quality: .major),
            Chord(root: .A, quality: .minor),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.root, .A)
        XCTAssertEqual(key?.mode, .minor)
    }

    func testInferKeyCadentialVI() {
        let chords = [
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNotNil(key)
    }

    func testInferKeyWithCadence() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .F, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.root, .C)
        XCTAssertEqual(key?.mode, .major)
    }

    func testInferKeySingleChordReturnsNil() {
        let chords = [Chord(root: .C, quality: .major)]
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNil(key)
    }

    func testInferKeyEmptyReturnsNil() {
        let chords: [Chord] = []
        let key = ProgressionAnalyzer.inferKey(from: chords)
        XCTAssertNil(key)
    }

    func testInferKey24KeyRoundTrip() {
        let roots: [NoteName] = [.C, .Cs, .D, .Ds, .E, .F, .Fs, .G, .Gs, .A, .As, .B]
        for root in roots {
            for mode in [KeyMode.major, KeyMode.minor] {
                let key = MusicalKey(root: root, mode: mode)
                let diatonicChords = DiatonicChordGenerator.generate(for: key).prefix(4)
                let chords = diatonicChords.map { Chord(root: $0.root.noteName, quality: $0.quality) }

                let inferredKey = ProgressionAnalyzer.inferKey(from: Array(chords))
                XCTAssertNotNil(inferredKey, "Failed to infer key for \(key.displayName)")
            }
        }
    }

    // MARK: - RecognizePattern Tests

    func testRecognizePatternPopAnthemExact() {
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

    func testRecognizePatternSensitiveExact() {
        let chords = [
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Sensitive/Emotional")
        XCTAssertEqual(result?.matchType, .exact)
    }

    func testRecognizePatternFuzzyMatch() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .E, quality: .minor),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchType, .similar)
    }

    func testRecognizePatternPhrygianCadence() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
    }

    func testRecognizePatternCanonInDExact() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .E, quality: .minor),
            Chord(root: .F, quality: .major),
            Chord(root: .C, quality: .major),
            Chord(root: .F, quality: .major),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Canon in D")
        XCTAssertEqual(result?.matchType, .exact)
    }

    func testRecognizePatternTooShortReturnsNil() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNil(result)
    }

    func testRecognizePatternNoMatchReturnsNil() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .Ds, quality: .major),
            Chord(root: .E, quality: .major),
            Chord(root: .Fs, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNil(result)
    }

    func testRecognizePatternJazzStandard() {
        let chords = [
            Chord(root: .D, quality: .minor),
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Jazz Standard")
        XCTAssertEqual(result?.matchType, .exact)
    }

    func testRecognizePatternSongExamplesPreserved() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        let examples = result!.songExamples
        XCTAssertGreaterThan(examples.count, 0)
        XCTAssertTrue(examples.contains { $0.songTitle == "Let It Be" })
    }

    func testRecognizePatternDisplayString() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        let displayString = result!.displayString
        XCTAssertEqual(displayString, "I–V–vi–IV")
    }

    func testRecognizePatternAllDiatonicCMajor() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .D, quality: .minor),
            Chord(root: .E, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNil(result)
    }

    func testRecognizePatternClassicRock() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .F, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Classic Rock/Folk")
    }

    func testRecognizePattern50sDooWop() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "50s Doo-wop")
    }

    func testRecognizePatternJazzTurnaround() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .D, quality: .minor),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Jazz Turnaround")
    }

    func testRecognizePatternMixolydianRock() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .As, quality: .major),
            Chord(root: .F, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Mixolydian Rock")
    }

    func testRecognizePatternBuildingUplifting() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .F, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .G, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Building/Uplifting")
    }

    func testRecognizePatternDreamyNostalgic() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .E, quality: .minor),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Dreamy/Nostalgic")
    }
}
