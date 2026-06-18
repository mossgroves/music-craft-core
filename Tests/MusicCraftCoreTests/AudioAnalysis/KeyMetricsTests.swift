import XCTest
@testable import MusicCraftCore

/// Guards `AudioAnalysisMetrics.compareKey` — the grader for every key-accuracy benchmark.
/// Before 2026-06-18 it compared the uppercase detected string ("E:major") to a lowercased ground
/// truth ("e:major"), so `exactMatch` was structurally impossible, and it spelled sharp while JAMS
/// spells flat (D# vs Eb). The "0% exact" GuitarSet number was therefore a measurement artifact,
/// not the detector's true accuracy. These tests pin the pitch-class comparison so a real baseline
/// can be trusted. (Step 0 of docs/specs/tonic-key-detection-redesign.md.)
final class KeyMetricsTests: XCTestCase {

    private func key(_ root: NoteName, _ mode: KeyMode) -> MusicalKey { MusicalKey(root: root, mode: mode) }

    func testExactMatchNowPossible() {
        // The headline bug: this used to be false because "E:major" != "e:major".
        let m = AudioAnalysisMetrics.compareKey(detected: key(.E, .major), groundTruthJAMS: "E:major")
        XCTAssertTrue(m.exactMatch)
        XCTAssertTrue(m.relativeKeyMatch)
        XCTAssertTrue(m.rootMatch)
    }

    func testEnharmonicExactMatch() {
        // The detector spells sharp (D#), JAMS spells flat (Eb) — same key, must match by pitch class.
        XCTAssertTrue(AudioAnalysisMetrics.compareKey(detected: key(.Ds, .major), groundTruthJAMS: "Eb:major").exactMatch)
        XCTAssertTrue(AudioAnalysisMetrics.compareKey(detected: key(.As, .minor), groundTruthJAMS: "Bb:minor").exactMatch)
        XCTAssertTrue(AudioAnalysisMetrics.compareKey(detected: key(.Gs, .major), groundTruthJAMS: "Ab:major").exactMatch)
    }

    func testRelativeKeyMatch() {
        // A minor is the relative of C major (same notes, swapped tonic): relative yes, exact no.
        let m = AudioAnalysisMetrics.compareKey(detected: key(.A, .minor), groundTruthJAMS: "C:major")
        XCTAssertFalse(m.exactMatch)
        XCTAssertTrue(m.relativeKeyMatch)
        // And the other direction: C major detected against an A:minor truth.
        XCTAssertTrue(AudioAnalysisMetrics.compareKey(detected: key(.C, .major), groundTruthJAMS: "A:minor").relativeKeyMatch)
    }

    func testParallelIsRootMatchNotExact() {
        // C major vs C minor: same root, different mode.
        let m = AudioAnalysisMetrics.compareKey(detected: key(.C, .major), groundTruthJAMS: "C:minor")
        XCTAssertFalse(m.exactMatch)
        XCTAssertTrue(m.rootMatch)
        XCTAssertFalse(m.relativeKeyMatch)
    }

    func testFifthApartIsACleanMiss() {
        // D major vs G major (the bug class): different root, not relative — not exact, not root, not relative.
        let m = AudioAnalysisMetrics.compareKey(detected: key(.G, .major), groundTruthJAMS: "D:major")
        XCTAssertFalse(m.exactMatch)
        XCTAssertFalse(m.rootMatch)
        XCTAssertFalse(m.relativeKeyMatch)
    }

    func testRootPitchClassParsing() {
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("C"), 0)
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("F#"), 6)
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("Gb"), 6)   // enharmonic of F#
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("Eb"), 3)
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("D#"), 3)
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("Bb"), 10)
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("B"), 11)   // leading b is the note B
        XCTAssertEqual(AudioAnalysisMetrics.keyRootPitchClass("A♯"), 10)  // unicode sharp
    }
}
