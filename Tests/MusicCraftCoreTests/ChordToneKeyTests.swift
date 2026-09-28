import XCTest
@testable import MusicCraftCore

/// `AudioExtractor.chordToneKey` (0.1.22): the key from the chords' tones over their time, correlated
/// with the Krumhansl-Kessler profiles. Pins the case that replaced the progression scorer on this path
/// (a Bm-G-A song whose A had no third read A minor), that time and not the chord count decides, the
/// common shapes, and the nil cases the melody fallback owns. The GuitarSet measurement behind it lives
/// in Songcatcher's docs/audits/key-rule-2026-09-27.md.
final class ChordToneKeyTests: XCTestCase {

    private func chord(_ root: NoteName, _ quality: ChordQuality) -> Chord {
        Chord(root: root, quality: quality)
    }

    /// Consecutive segments, each lasting its given seconds.
    private func segments(_ spec: [(Chord, TimeInterval)]) -> [AudioExtractor.ChordSegment] {
        var start: TimeInterval = 0
        return spec.map { chord, seconds in
            defer { start += seconds }
            return AudioExtractor.ChordSegment(startTime: start, endTime: start + seconds, chord: chord,
                                               confidence: 0.8, detectionMethod: .classifier)
        }
    }

    func testABmGASongWhoseAHasNoThirdIsNotAMinor() {
        // The shape of the take that started it: Bm and G ring long; the A is voiced sus4, sus2 and
        // bare fifths, eleven short segments that say nothing about major or minor. The progression
        // scorer called it A minor (A minor 23, B minor 17).
        var spec: [(Chord, TimeInterval)] = []
        spec += Array(repeating: (chord(.B, .minor), 4.0), count: 3)
        spec += Array(repeating: (chord(.G, .major), 3.0), count: 3)
        spec += Array(repeating: (chord(.A, .sus4), 1.0), count: 6)
        spec += Array(repeating: (chord(.A, .sus2), 1.0), count: 3)
        spec.append((chord(.A, .power), 1.0))
        let key = AudioExtractor.chordToneKey(from: segments(spec))
        XCTAssertEqual(key, MusicalKey(root: .B, mode: .minor))
        XCTAssertNotEqual(key, MusicalKey(root: .A, mode: .minor))
    }

    func testTimeNotTheChordCountDecides() {
        // The same three shapes; whichever chord rings longest names the key.
        XCTAssertEqual(AudioExtractor.chordToneKey(from: segments([
            (chord(.C, .major), 10), (chord(.G, .major), 1), (chord(.A, .minor), 1),
        ])), MusicalKey(root: .C, mode: .major))
        XCTAssertEqual(AudioExtractor.chordToneKey(from: segments([
            (chord(.C, .major), 1), (chord(.G, .major), 10), (chord(.D, .major), 1),
        ])), MusicalKey(root: .G, mode: .major))
    }

    func testTheCommonShapesReadAsTheyShould() {
        XCTAssertEqual(AudioExtractor.chordToneKey(from: segments([
            (chord(.C, .major), 2), (chord(.F, .major), 2), (chord(.G, .major), 2), (chord(.C, .major), 2),
        ])), MusicalKey(root: .C, mode: .major))
        XCTAssertEqual(AudioExtractor.chordToneKey(from: segments([
            (chord(.A, .minor), 2), (chord(.D, .minor), 2), (chord(.E, .major), 2), (chord(.A, .minor), 2),
        ])), MusicalKey(root: .A, mode: .minor))
    }

    func testTooLittleHarmonyIsLeftToTheMelodyFallback() {
        XCTAssertNil(AudioExtractor.chordToneKey(from: []))
        XCTAssertNil(AudioExtractor.chordToneKey(from: segments([(chord(.C, .major), 4)])))
        // NOT pinned: two segments of the same chord. The gate is `Set(chords).count >= 2`, as it was
        // before 0.1.22, and `Chord`'s synthesized Hashable hashes its per-instance id while its `==`
        // compares root and quality only, so two pipeline-made C majors count as two. Left as it was
        // (a change to when the melody fallback runs is its own measured decision), noted in 0.1.22.
        XCTAssertNil(AudioExtractor.chordToneKey(from: segments([(chord(.C, .major), 0), (chord(.G, .major), 0)])),
                     "no segment has length")
    }

    func testTheAnswerIsTheSameEveryTime() {
        let spec = segments([(chord(.E, .minor), 3), (chord(.C, .major), 3), (chord(.G, .major), 3), (chord(.D, .major), 3)])
        let first = AudioExtractor.chordToneKey(from: spec)
        for _ in 0..<20 {
            XCTAssertEqual(AudioExtractor.chordToneKey(from: spec), first)
        }
    }

    func testPearsonIsZeroForAFlatProfile() {
        XCTAssertEqual(AudioExtractor.pearson([Double](repeating: 1, count: 12), AudioExtractor.majorKeyProfile), 0)
        XCTAssertEqual(AudioExtractor.pearson(AudioExtractor.majorKeyProfile, AudioExtractor.majorKeyProfile), 1, accuracy: 1e-12)
    }
}
