import XCTest
@testable import MusicCraftCore

/// The exact shape the first harness run on 0.1.17 produced on Highest Heaven's outro
/// (2026-09-02): with the brake on, the decoder alternated a capped "oh" chant with a single
/// "yeah", and one pass of the run guard removed the chants and left eleven "yeah"s touching.
/// Pinned here so the guard's fixed-point behaviour on a real specimen is a test, not a table.
final class RepetitionGuardSpecimenTests: XCTestCase {
    private func token(_ text: String, _ index: Int) -> TranscribedToken {
        TranscribedToken(text: text, onsetTime: 240 + Double(index) * 0.5, duration: 0.3, confidence: 0.9)
    }

    func testChantsSeparatedBySingleWordsCollapseToNothing() {
        // yeah, oh×6, yeah, oh×6, yeah, oh×6, yeah, oh×6, yeah, oh×6, yeah  → after the ohs go,
        // six "yeah" touch, and they go too.
        var texts: [String] = []
        for _ in 0..<5 { texts += ["yeah,"] + Array(repeating: "oh,", count: 6) }
        texts += ["yeah,"]
        let segment = texts.enumerated().map { token($1, $0) }

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 285)

        XCTAssertTrue(filtered.isEmpty, filtered.map(\.text).joined(separator: " "))
    }

    func testOnePassAloneWouldHaveLeftTheWall() {
        var texts: [String] = []
        for _ in 0..<5 { texts += ["yeah,"] + Array(repeating: "oh,", count: 6) }
        texts += ["yeah,"]
        let segment = texts.enumerated().map { token($1, $0) }

        let once = WhisperLyricsEngine.droppingRepetitionRunsOnce([segment]).flatMap { $0 }

        XCTAssertEqual(once.map(\.text), Array(repeating: "yeah,", count: 6))
    }

    func testWordsThatStandBetweenChantsAreKeptWhenTheyDoNotFormARun() {
        // "the oh×6 highest oh×6 heaven": the ohs go, the three real words stay.
        let texts = ["the"] + Array(repeating: "oh,", count: 6) + ["highest"] + Array(repeating: "oh,", count: 6) + ["heaven"]
        let segment = texts.enumerated().map { token($1, $0) }

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 285)

        XCTAssertEqual(filtered.map(\.text), ["the", "highest", "heaven"])
    }
}
