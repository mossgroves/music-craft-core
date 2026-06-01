import XCTest
@testable import MusicCraftCore

/// Synthetic, deterministic tests for `NoteChordIdentifier` — name a chord from a weighted
/// pitch-class histogram + bass, compared via `chord.displayName`. Theory-only; no audio, no model.
final class NoteChordIdentifierTests: XCTestCase {

    /// Build a 12-element histogram with weight 1.0 on each named pitch class.
    private func hist(_ pcs: [Int], extra: [(pc: Int, w: Double)] = []) -> [Double] {
        var h = [Double](repeating: 0, count: 12)
        for pc in pcs { h[((pc % 12) + 12) % 12] = 1.0 }
        for e in extra { h[((e.pc % 12) + 12) % 12] += e.w }
        return h
    }

    private func name(_ pcs: [Int], bass: Int?, extra: [(pc: Int, w: Double)] = []) -> String? {
        NoteChordIdentifier.identify(weightedPitchClasses: hist(pcs, extra: extra), bassPitchClass: bass)?.chord.displayName
    }

    func testMajorTriad() {
        XCTAssertEqual(name([0, 4, 7], bass: 0), "C")            // C E G
    }

    func testMinorTriad() {
        XCTAssertEqual(name([9, 0, 4], bass: 9), "Am")           // A C E
    }

    func testMajorSeventh() {
        XCTAssertEqual(name([0, 4, 7, 11], bass: 0), "Cmaj7")    // C E G B
    }

    func testDominantSeventh() {
        XCTAssertEqual(name([0, 4, 7, 10], bass: 0), "C7")       // C E G B♭
    }

    func testSus2() {
        XCTAssertEqual(name([0, 2, 7], bass: nil), "Csus2")      // C D G
    }

    func testSus4() {
        XCTAssertEqual(name([0, 5, 7], bass: nil), "Csus4")      // C F G
    }

    func testDiminished() {
        XCTAssertEqual(name([0, 3, 6], bass: 0), "C°")           // C E♭ G♭
    }

    func testAugmented() {
        XCTAssertEqual(name([0, 4, 8], bass: 0), "C+")           // C E G♯
    }

    /// Robustness: a major triad with a small extra weight on D must still name C — not get
    /// promoted to sus2 / add9 by a little leakage.
    func testMajorTriadWithSmallExtraStaysMajor() {
        XCTAssertEqual(name([0, 4, 7], bass: 0, extra: [(pc: 2, w: 0.15)]), "C")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(NoteChordIdentifier.identify(weightedPitchClasses: [Double](repeating: 0, count: 12), bassPitchClass: nil))
    }

    func testSingleNoteReturnsNil() {
        XCTAssertNil(NoteChordIdentifier.identify(weightedPitchClasses: hist([0]), bassPitchClass: 0))
    }
}
