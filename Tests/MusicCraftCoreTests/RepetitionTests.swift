import CoreML
import XCTest
@testable import MusicCraftCore

/// The two repetition defences added in 0.1.17 (Chris's word 2026-09-02, measured in Sanctuary's
/// `docs/audits/repetition-levers-2026-09-01.md`): the run guard in the artifact filter and the
/// decode-time brake. Pure logic, no model, no audio.
final class RepetitionTests: XCTestCase {
    private func token(_ text: String, onset: TimeInterval, confidence: Double? = 0.9) -> TranscribedToken {
        TranscribedToken(text: text, onsetTime: onset, duration: 0.3, confidence: confidence)
    }

    private func run(_ word: String, count: Int, from onset: TimeInterval) -> [TranscribedToken] {
        (0..<count).map { token(word, onset: onset + Double($0) * 0.3) }
    }

    // MARK: - The run guard (filterArtifacts rule 3)

    func testFiveIdenticalWordsInARowAreDroppedAndFourAreKept() {
        let five = [token("I", onset: 0)] + run("oh,", count: 5, from: 1) + [token("home", onset: 3)]
        let four = [token("I", onset: 0)] + run("oh,", count: 4, from: 1) + [token("home", onset: 3)]

        XCTAssertEqual(WhisperLyricsEngine.filterArtifacts(segments: [five], audioDuration: 120).map(\.text),
                       ["I", "home"])
        XCTAssertEqual(WhisperLyricsEngine.filterArtifacts(segments: [four], audioDuration: 120).map(\.text),
                       ["I", "oh,", "oh,", "oh,", "oh,", "home"])
    }

    func testCaseAndPunctuationDoNotHideARun() {
        // The brake's escape hatch, closed: "Oh," and "oh" and "OH!" are one word.
        let segment = [token("Oh,", onset: 0), token("oh,", onset: 0.3), token("OH!", onset: 0.6),
                       token("oh", onset: 0.9), token("Oh", onset: 1.2), token("home", onset: 2)]

        XCTAssertEqual(WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120).map(\.text),
                       ["home"])
    }

    func testARunSpanningTwoSegmentsIsOneRun() {
        // The brake caps a chant at five per segment; the model restarts it in the next segment.
        // Three plus three is six, and six is a run.
        let first = [token("we", onset: 0)] + run("yeah", count: 3, from: 1)
        let second = run("yeah", count: 3, from: 2) + [token("fly", onset: 3)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [first, second], audioDuration: 120)

        XCTAssertEqual(filtered.map(\.text), ["we", "fly"])
        // Segment boundaries survive on the words that survive.
        XCTAssertEqual(filtered.map(\.startsSegment), [true, true])
    }

    func testTheVerseBehindTheLoopSurvives() {
        // The 6 Human shape: 78 "so" and then the real verse, in one window, sharing timestamps.
        // Convict by run, never by shared onset, or the verse goes with the junk.
        let loop = (0..<78).map { _ in token("so,", onset: 87.0) }
        let verse = ["I", "get", "lost,", "I", "get", "scared"].map { token($0, onset: 87.0) }

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [[token("myself", onset: 60)] + loop + verse],
                                                           audioDuration: 279)

        XCTAssertEqual(filtered.map(\.text), ["myself", "I", "get", "lost,", "I", "get", "scared"])
    }

    func testAPunctuationOnlyTokenBreaksARun() {
        let segment = run("oh", count: 3, from: 0) + [token("...", onset: 1)] + run("oh", count: 3, from: 2)

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120)

        XCTAssertEqual(filtered.count, 7)
    }

    func testARealRepeatedHookUnderTheFloorIsUntouched() {
        // Te Amo's "limpia, limpia, limpia, limpia mi corazón": four, not five.
        let segment = run("limpia,", count: 4, from: 15) + [token("mi", onset: 17), token("corazón", onset: 17.3)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120)

        XCTAssertEqual(filtered.count, 6)
    }

    func testTheTrailingRuleStillAppliesAfterARunIsDropped() {
        // A run at the end followed by a lone weak sign-off: the run goes by rule 3, the tail by rule 4.
        let verse = [token("last", onset: 100), token("line", onset: 100.4)]
        let tail = run("oh", count: 6, from: 101) + [token("you", onset: 110, confidence: 0.1)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [verse, tail], audioDuration: 120)

        XCTAssertEqual(filtered.map(\.text), ["last", "line"])
    }

    func testTheFloorIsFiveAndTheFoldIsShared() {
        XCTAssertEqual(WhisperLyricsEngine.repetitionRunFloor, 5)
        XCTAssertEqual(RepetitionBrake.maxRepeats, 5)
        XCTAssertEqual(RepetitionBrake.fold(" Oh,"), "oh")
        XCTAssertEqual(RepetitionBrake.fold("..."), "")
        XCTAssertEqual(RepetitionBrake.fold(" corazón"), "corazón")
    }

    // MARK: - The brake's rule (pure)

    func testTheSixthRepeatOfOneWordIsForbiddenAndTheFifthIsNot() {
        XCTAssertEqual(RepetitionBrake.forbiddenContinuation(after: Array(repeating: "oh", count: 5)), "oh")
        XCTAssertNil(RepetitionBrake.forbiddenContinuation(after: Array(repeating: "oh", count: 4)))
        XCTAssertNil(RepetitionBrake.forbiddenContinuation(after: ["oh", "oh", "oh", "oh", "no"]))
    }

    func testATwoWordBlockRepeatedFiveTimesIsCaught() {
        // The Lujah loop: "alaihi loo" ×5 forbids "alaihi".
        let words = Array(repeating: ["alaihi", "loo"], count: 5).flatMap { $0 }
        XCTAssertEqual(RepetitionBrake.forbiddenContinuation(after: words), "alaihi")
        XCTAssertNil(RepetitionBrake.forbiddenContinuation(after: Array(words.dropFirst(2))))
    }

    func testOnlyTheTailCounts() {
        let words = Array(repeating: "oh", count: 5) + ["ever", "seeing", "eternity"]
        XCTAssertNil(RepetitionBrake.forbiddenContinuation(after: words))
    }

    func testBlocksLongerThanFourWordsAreNotWatched() {
        let block = ["a", "b", "c", "d", "e"]
        XCTAssertNil(RepetitionBrake.forbiddenContinuation(after: Array(repeating: block, count: 5).flatMap { $0 }))
    }

    // MARK: - The brake over logits

    private func logits(count: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: count)], dataType: .float32)
        for i in 0..<count { array[[0, 0, NSNumber(value: i)]] = 1.0 }
        return array
    }

    func testEverySpellingOfTheRepeatedWordIsSuppressedTogether() throws {
        // ids 1 " oh", 2 " Oh", 3 " oh," fold to "oh"; id 4 "," folds to nothing; 5 " home"; 9 is a
        // special token and invisible.
        let brake = RepetitionBrake(foldTable: [1: "oh", 2: "oh", 3: "oh", 5: "home"], specialTokenBegin: 9)
        let tokens = [9, 1, 4, 2, 4, 3, 4, 1, 4, 2]   // oh , oh , oh , oh , oh  → five "oh"

        let filtered = brake.filterLogits(try logits(count: 10), withTokens: tokens)

        for id in [1, 2, 3] { XCTAssertEqual(filtered[[0, 0, NSNumber(value: id)]].floatValue, -.infinity) }
        for id in [0, 4, 5, 9] { XCTAssertEqual(filtered[[0, 0, NSNumber(value: id)]].floatValue, 1.0) }
    }

    func testFourRepeatsLeaveTheLogitsAlone() throws {
        let brake = RepetitionBrake(foldTable: [1: "oh", 2: "oh", 5: "home"], specialTokenBegin: 9)

        let filtered = brake.filterLogits(try logits(count: 10), withTokens: [9, 1, 2, 1, 2])

        for id in 0..<10 { XCTAssertEqual(filtered[[0, 0, NSNumber(value: id)]].floatValue, 1.0) }
    }
}
