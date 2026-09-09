import XCTest
import WhisperKit
@testable import MusicCraftCore

/// Pure-logic tests for the Whisper lyric path: WordTiming → TranscribedToken mapping and the
/// measured artifact filter. No model, no audio, no network — these run in every suite pass.
/// Evidence for every threshold lives in WhisperLyricsEngine's doc comments (six-song on-device
/// scoring, Sanctuary BACKLOG "Lyric transcription", 2026-08-07).
final class WhisperLyricsEngineTests: XCTestCase {
    // MARK: - Helpers

    /// Shorthand token builder for filter tests.
    private func token(
        _ text: String,
        onset: TimeInterval = 0,
        duration: TimeInterval = 0.4,
        confidence: Double? = 0.9
    ) -> TranscribedToken {
        TranscribedToken(text: text, onsetTime: onset, duration: duration, confidence: confidence)
    }

    // MARK: - WordTiming → TranscribedToken mapping

    func testMappingCarriesTimingAndProbability() {
        // Whisper's leading-space token convention: " Hello" is the raw word text.
        let words = [
            WordTiming(word: " Hello", tokens: [], start: 1.0, end: 1.5, probability: 0.92),
            WordTiming(word: " world", tokens: [], start: 1.5, end: 2.1, probability: 0.4),
        ]

        let tokens = WhisperLyricsEngine.tokens(fromWords: words)

        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].text, "Hello")
        XCTAssertEqual(tokens[0].onsetTime, 1.0, accuracy: 1e-6)
        XCTAssertEqual(tokens[0].duration, 0.5, accuracy: 1e-6)
        XCTAssertEqual(tokens[0].confidence ?? -1, 0.92, accuracy: 1e-6)
        XCTAssertEqual(tokens[1].text, "world")
        XCTAssertEqual(tokens[1].confidence ?? -1, 0.4, accuracy: 1e-6)
    }

    func testMappingDropsWhitespaceOnlyWordsAndClampsNegativeDuration() {
        let words = [
            WordTiming(word: "  ", tokens: [], start: 0.0, end: 0.2, probability: 0.9),
            // Degenerate timing (end before start) must not produce a negative duration.
            WordTiming(word: " oops", tokens: [], start: 2.0, end: 1.8, probability: 0.7),
        ]

        let tokens = WhisperLyricsEngine.tokens(fromWords: words)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].text, "oops")
        XCTAssertEqual(tokens[0].duration, 0, accuracy: 1e-6)
    }

    // MARK: - Artifact filter rule 1: ghost-word confidence floor

    func testGhostWordsBelowFloorAreDropped() {
        // Ghost words measured at probability 0.03-0.19; the floor (0.15) drops the low band
        // while legit quiet words (higher probability) stay.
        let segment = [
            token("the", onset: 1.0, confidence: 0.85),
            token("ghost", onset: 1.4, confidence: 0.03),
            token("whisper", onset: 1.8, confidence: 0.14),
            token("stays", onset: 2.2, confidence: 0.15), // exactly at the floor: kept
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120)

        XCTAssertEqual(filtered.map(\.text), ["the", "stays"])
    }

    // MARK: - The take's opening word (2026-08-10)

    /// THE BUG THIS FIXES, in Chris's words: *"Forever analysis also lost the opening, first word
    /// of the song."* Whisper under-scores a take's first word for reasons unrelated to whether
    /// it was sung — no left context after the prefill, opening syllable caught mid-attack over a
    /// music bed. Measured across the six scored songs the opening word runs 0.06 to 0.48 (median
    /// 0.215) against a corpus median of 0.98, so a floor drawn against hallucinations ate two of
    /// six real openings.
    func testTheTakesFirstWordSurvivesBelowTheFloor() {
        // "1 Forever" opens "Forever I have looked"; the export read "I have looked".
        let segment = [
            token("Forever", onset: 0.4, confidence: 0.06),
            token("I", onset: 0.9, confidence: 0.97),
            token("have", onset: 1.1, confidence: 0.98),
            token("looked", onset: 1.4, confidence: 0.96),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 248)

        XCTAssertEqual(filtered.map(\.text), ["Forever", "I", "have", "looked"])
    }

    /// THE EXEMPTION IS ONE TOKEN, NOT A HOLE. A ghost immediately after the opening word is
    /// still a ghost.
    func testOnlyTheVeryFirstWordIsExempt() {
        let segment = [
            token("Forever", onset: 0.4, confidence: 0.06),
            token("ghost", onset: 0.7, confidence: 0.04),
            token("I", onset: 0.9, confidence: 0.97),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 248)

        XCTAssertEqual(filtered.map(\.text), ["Forever", "I"])
    }

    /// And it is spent on the TAKE, not on every segment: a low-confidence word opening the
    /// second segment is judged by the floor like any other.
    func testLaterSegmentsGetNoExemption() {
        let first = [token("Forever", onset: 0.4, confidence: 0.06),
                     token("I", onset: 0.9, confidence: 0.97)]
        let second = [token("ghost", onset: 30.0, confidence: 0.05),
                      token("real", onset: 30.4, confidence: 0.92)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [first, second],
                                                           audioDuration: 248)

        XCTAssertEqual(filtered.map(\.text), ["Forever", "I", "real"])
    }

    /// The exemption must not resurrect a "Music" caption: rule (1) drops that whole segment
    /// BEFORE the floor runs, and the opening exemption then belongs to the first real segment.
    /// ("Highest Heaven" opens with a genuine `Music` caption at p=0.09.)
    func testAMusicCaptionNeverBecomesTheExemptOpeningWord() {
        let caption = [token("Music", onset: 0.1, confidence: 0.09)]
        let firstReal = [token("Listen", onset: 4.0, confidence: 0.12),
                         token("to", onset: 4.3, confidence: 0.95)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [caption, firstReal],
                                                           audioDuration: 275)

        XCTAssertEqual(filtered.map(\.text), ["Listen", "to"],
                       "the caption goes; the first REAL word inherits the exemption")
    }

    func testNilConfidenceIsKept() {
        // Only the Whisper path sets confidence; a nil-confidence token has nothing to judge
        // it by and must survive the floor.
        let segment = [token("word", confidence: nil)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120)

        XCTAssertEqual(filtered.map(\.text), ["word"])
    }

    // MARK: - Artifact filter rule 2: "Music" caption segments

    func testMusicOnlySegmentIsDroppedEvenAtHighConfidence() {
        // The instrumental-intro/fade caption artifact: a segment containing only "Music".
        // Confidence is irrelevant — the model is often confident it is captioning music.
        let musicSegment = [token("Music", onset: 2.0, confidence: 0.95)]
        let lyricSegment = [
            token("first", onset: 20.0, confidence: 0.9),
            token("words", onset: 20.5, confidence: 0.9),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [musicSegment, lyricSegment],
            audioDuration: 120
        )

        XCTAssertEqual(filtered.map(\.text), ["first", "words"])
    }

    func testRepeatedAndBracketedMusicTokensStillMatchTheArtifactShape() {
        let musicSegment = [
            token("[Music]", onset: 2.0),
            token("music", onset: 4.0),
            token("MUSIC.", onset: 6.0),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [musicSegment], audioDuration: 120)

        XCTAssertTrue(filtered.isEmpty)
    }

    func testLyricContainingTheWordMusicIsKept() {
        // "music" among real words is a lyric, not a caption — only the only-"Music" segment
        // shape is the measured artifact.
        let segment = [
            token("music", onset: 10.0),
            token("is", onset: 10.4),
            token("my", onset: 10.7),
            token("life", onset: 11.0),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [segment], audioDuration: 120)

        XCTAssertEqual(filtered.map(\.text), ["music", "is", "my", "life"])
    }

    // MARK: - Artifact filter rule 3: trailing lone low-confidence token at end-of-audio

    func testTrailingLoneLowConfidenceTokenAtEndOfAudioIsDropped() {
        // The measured "you" tail: a lone final token, low confidence, over the fade-out.
        let verse = [
            token("last", onset: 100.0, confidence: 0.9),
            token("line", onset: 100.5, confidence: 0.9),
        ]
        let tail = [token("you", onset: 118.0, duration: 0.3, confidence: 0.2)]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [verse, tail],
            audioDuration: 120
        )

        XCTAssertEqual(filtered.map(\.text), ["last", "line"])
    }

    func testTrailingLoneTokenWithHighConfidenceIsKept() {
        // A confident final word is a real lyric ending, not the tail artifact.
        let verse = [token("goodbye", onset: 100.0, confidence: 0.9)]
        let ending = [token("love", onset: 118.0, confidence: 0.8)]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [verse, ending],
            audioDuration: 120
        )

        XCTAssertEqual(filtered.map(\.text), ["goodbye", "love"])
    }

    func testLoneLowConfidenceTokenAwayFromEndOfAudioIsKept() {
        // The tail rule only fires inside the final decode window (30 s) of the audio; a lone
        // quiet word mid-song is legitimate material.
        let quiet = [token("hush", onset: 60.0, duration: 0.3, confidence: 0.2)]
        let verse = [
            token("after", onset: 100.0, confidence: 0.9),
            token("that", onset: 100.4, confidence: 0.9),
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [quiet, verse],
            audioDuration: 300
        )

        XCTAssertEqual(filtered.map(\.text), ["hush", "after", "that"])
    }

    func testTrailingRuleAppliesAfterGhostFloorLeavesALoneToken() {
        // A final segment reduced to one low-confidence token by the ghost floor is still the
        // tail shape: the rules compose (floor first, then the trailing check on the remnant).
        let verse = [token("real", onset: 90.0, confidence: 0.9)]
        let tail = [
            token("ghost", onset: 117.0, confidence: 0.05), // dropped by the floor
            token("you", onset: 118.0, confidence: 0.22), // then a lone trailing low-conf token
        ]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [verse, tail],
            audioDuration: 120
        )

        XCTAssertEqual(filtered.map(\.text), ["real"])
    }

    // MARK: - Filter output shape

    func testFilterFlattensInSegmentOrderAndEmptyInputIsEmpty() {
        XCTAssertTrue(WhisperLyricsEngine.filterArtifacts(segments: [], audioDuration: 0).isEmpty)

        let first = [token("one", onset: 1.0), token("two", onset: 1.5)]
        let second = [token("three", onset: 40.0)]

        let filtered = WhisperLyricsEngine.filterArtifacts(
            segments: [first, second],
            audioDuration: 120
        )

        XCTAssertEqual(filtered.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(filtered.map(\.onsetTime), filtered.map(\.onsetTime).sorted())
    }

    // MARK: - Artifact filter rule 3, the phrase axis (P-2026-09-08-17, 2026-09-09)

    /// The measured loops from the JamendoLyrics 20 and his Instrumental 2, as fixtures: the
    /// hallucinated phrase and the repeat count are the ones the 2026-09-08 mint produced
    /// (Sanctuary `docs/audits/public-corpus-2026-09-08.md`). Every one has a longest
    /// single-word run of 1 or 2, which is why the one-word rule let them through. The loops
    /// are Whisper's inventions and occur in no reference. The SUNG lines around them are
    /// stand-ins of the same word count, never the lyric: the public-corpus rule keeps every
    /// reference line out of this tree, and the assertions depend only on shape (a line, a
    /// loop, a line).

    private func phrase(_ words: [String], times: Int, from onset: TimeInterval) -> [TranscribedToken] {
        (0..<times).flatMap { copy in
            words.enumerated().map { index, word in
                token(word, onset: onset + Double(copy * words.count + index) * 0.3)
            }
        }
    }

    private func line(_ words: [String], from onset: TimeInterval) -> [TranscribedToken] {
        words.enumerated().map { index, word in
            token(word, onset: onset + Double(index) * 0.3)
        }
    }

    private func line(_ text: String, from onset: TimeInterval) -> [TranscribedToken] {
        line(text.split(separator: " ").map(String.init), from: onset)
    }

    /// Neutral stand-in words of a given count: "tag1 tag2 ... tagN".
    private func filler(_ count: Int, _ tag: String) -> [String] {
        (1...count).map { "\(tag)\($0)" }
    }

    private func filtered(_ segments: [[TranscribedToken]]) -> [String] {
        WhisperLyricsEngine.filterArtifacts(segments: segments, audioDuration: 240).map(\.text)
    }

    func testTheMeasuredPhraseLoopsAreDroppedWholeAndTheLinesAroundThemSurvive() {
        // One Way Street: 8 words x8 over the sung first verse, between a 7-word line and a
        // 9-word line.
        let oneWayBefore = filler(7, "verse")
        let oneWayAfter = filler(9, "next")
        let oneWay = line(oneWayBefore, from: 1)
            + phrase(["if", "you", "can", "hear", "me", "I'm", "not", "sure"], times: 8, from: 3)
            + line(oneWayAfter, from: 27)
        XCTAssertEqual(filtered([oneWay]), oneWayBefore + oneWayAfter)

        // Crowd Pleaser: 6 words x11, a rotation of a 7-word hook that is sung once on each side.
        let hook = filler(7, "hook")
        let crowd = line(hook, from: 0)
            + phrase(["you", "down", "I'm", "not", "gonna", "let"], times: 11, from: 2)
            + line(hook, from: 30)
        XCTAssertEqual(filtered([crowd]), hook + hook)

        // HILA: 9 words x13, 117 tokens stamped on ONE onset. Outside any 2-8 word window.
        // A 4-word line before it, a 6-word line after.
        let hilaBefore = filler(4, "verse")
        let hilaAfter = filler(6, "next")
        let hila = line(hilaBefore, from: 20)
            + (0..<13).flatMap { _ in
                ["sure", "if", "you", "can", "see", "it", "but", "I'm", "not"].map { token($0, onset: 25.46, duration: 0) }
            }
            + line(hilaAfter, from: 60)
        XCTAssertEqual(filtered([hila]), hilaBefore + hilaAfter)

        // Wordsmith: 13 words x8 over the opening rap verse, then a 7-word line.
        let wordsmithAfter = filler(7, "verse")
        let wordsmith = phrase(["I'm", "a", "fan", "of", "the", "music", "I'm", "not", "a", "fan", "of", "the", "music"],
                               times: 8, from: 2)
            + line(wordsmithAfter, from: 20)
        XCTAssertEqual(filtered([wordsmith]), wordsmithAfter)

        // Keep On: the brake's fingerprint, a two-word block capped at exactly five, between a
        // 5-word line and a 4-word line.
        let keepOnBefore = filler(5, "verse")
        let keepOnAfter = filler(4, "next")
        let keepOn = line(keepOnBefore, from: 100)
            + phrase(["2", "3"], times: 5, from: 109)
            + line(keepOnAfter, from: 112)
        XCTAssertEqual(filtered([keepOn]), keepOnBefore + keepOnAfter)

        // His Instrumental 2 (no voice on the take): 11 words x8.
        let instrumental = phrase(["that", "I'm", "not", "sure", "if", "I'm", "gonna", "be", "able", "to", "do"],
                                  times: 8, from: 33)
        XCTAssertEqual(filtered([instrumental]), [])
    }

    func testCaseAndPunctuationDoNotHideAPhraseLoop() {
        // Like The Sun: "Do da da do." x5, the raw texts differing by case and punctuation only,
        // then an 8-word sung line.
        let vocalise = [["Do", "da", "da", "do."], ["do", "da", "da", "do"], ["Do", "da", "da", "do,"],
                        ["do", "da", "da", "do."], ["Do", "da", "da", "do"]]
            .enumerated().flatMap { copy, words in
                words.enumerated().map { index, word in token(word, onset: Double(copy * 4 + index) * 0.3) }
            }
        let after = filler(8, "verse")
        let segment = vocalise + line(after, from: 8)

        XCTAssertEqual(filtered([segment]), after)
    }

    func testAChorusRepeatedThreeOrFourTimesIsUntouched() {
        // Cortez: a 5-word hook x4 after an 11-word line, in three places of the song (the sheet
        // writes all four).
        let cortez = line(filler(11, "verse"), from: 90)
            + phrase(filler(5, "hook"), times: 4, from: 93)
        XCTAssertEqual(filtered([cortez]), cortez.map(\.text))

        // Crowd Pleaser's 3-word hook x3 (cased and punctuated as minted) and LUNABLIND's 4-word
        // hook x3: real repeats.
        let waits = [token("one,", onset: 48.5), token("two", onset: 48.8), token("three.", onset: 49.1),
                     token("One", onset: 49.4), token("two", onset: 49.7), token("three,", onset: 50.0),
                     token("one", onset: 50.3), token("two", onset: 50.6), token("three!", onset: 50.9)]
        XCTAssertEqual(filtered([waits]), waits.map(\.text))
        let firstTime = phrase(filler(4, "hook"), times: 3, from: 135)
        XCTAssertEqual(filtered([firstTime]), firstTime.map(\.text))

        // Wordsmith's 15-word chorus x4, whose opening pair repeats inside it (the period-2 scan
        // sees that pair twice, under the floor; the period-15 scan sees four copies).
        var chorusWords = filler(15, "chorus")
        chorusWords[2] = chorusWords[0]
        chorusWords[3] = chorusWords[1]
        let chorus = phrase(chorusWords, times: 4, from: 102)
        XCTAssertEqual(filtered([chorus]), chorus.map(\.text))

        // A 9-word block x4: above the 2-8 window, still under the floor.
        let nine = phrase(["sure", "if", "you", "can", "see", "it", "but", "I'm", "not"], times: 4, from: 0)
        XCTAssertEqual(filtered([nine]), nine.map(\.text))

        // Moon I Mean "we're not one" x4 is a hallucination the count cannot tell from Cortez;
        // the floor is five and it stays, deliberately.
        let moon = phrase(["we're", "not", "one"], times: 4, from: 32)
        XCTAssertEqual(filtered([moon]), moon.map(\.text))
    }

    func testATwoWordBlockRepeatedFiveTimesIsDroppedAndFourAreKept() {
        // The brake's own bar (the Lujah "alaihi loo" loop), now the guard's too.
        let five = line("we sing", from: 0) + phrase(["alaihi", "loo"], times: 5, from: 1) + line("tonight", from: 5)
        let four = line("we sing", from: 0) + phrase(["alaihi", "loo"], times: 4, from: 1) + line("tonight", from: 5)

        XCTAssertEqual(filtered([five]), ["we", "sing", "tonight"])
        XCTAssertEqual(filtered([four]), four.map(\.text))
    }

    func testAPhraseThatEndsWithItsFirstWordIsCaughtByItsPeriodNotByThePairs() {
        // "home take me home" x8: the one-word scan sees only pairs of "home"; the phrase scan
        // sees the block.
        let segment = line("carry me", from: 0) + phrase(["home", "take", "me", "home"], times: 8, from: 1)
        XCTAssertEqual(filtered([segment]), ["carry", "me"])
        let four = line("carry me", from: 0) + phrase(["home", "take", "me", "home"], times: 4, from: 1)
        XCTAssertEqual(filtered([four]), four.map(\.text))
    }

    func testAPhraseLoopSpanningSegmentsIsOneRun() {
        // Ridgway "i'm gonna go" x8, every copy its own segment (WhisperKit re-seeks inside the
        // slice and restarts the pattern per segment), between two 5-word lines whose four
        // "oh"s sit under the one-word floor.
        let edge = ["edge1", "oh", "oh", "oh", "oh"]
        let ridgway = [line(edge, from: 210)]
            + (0..<8).map { copy in phrase(["I'm", "gonna", "go"], times: 1, from: 214 + Double(copy) * 2) }
            + [line(edge, from: 232)]
        let survivors = WhisperLyricsEngine.filterArtifacts(segments: ridgway, audioDuration: 284)
        XCTAssertEqual(survivors.map(\.text), edge + edge)
        XCTAssertEqual(survivors.map(\.startsSegment), [true, false, false, false, false, true, false, false, false, false])

        // Three copies in one segment and two in the next are five, one run.
        let first = line("we", from: 0) + phrase(["oh", "yeah"], times: 3, from: 1)
        let second = phrase(["oh", "yeah"], times: 2, from: 3) + line("fly", from: 5)
        let split = WhisperLyricsEngine.filterArtifacts(segments: [first, second], audioDuration: 120)
        XCTAssertEqual(split.map(\.text), ["we", "fly"])
        XCTAssertEqual(split.map(\.startsSegment), [true, true])
    }

    func testAPhraseWhoseInteriorCollapsesIntoAOneWordRunStillTerminatesAndEmpties() {
        // "oh oh oh oh oh home" x5: the first pass is the one-word rule's (25 "oh"), which leaves
        // five "home" touching; the second pass takes those; the third finds nothing.
        let nested = phrase(["oh", "oh", "oh", "oh", "oh", "home"], times: 5, from: 0)
        XCTAssertEqual(filtered([nested]), [])

        // "oh oh oh home" x5: the interior is under the one-word floor, so the block's own
        // period convicts it in one pass.
        let shallow = phrase(["oh", "oh", "oh", "home"], times: 5, from: 0)
        XCTAssertEqual(filtered([shallow]), [])

        // The Highest Heaven specimen, pinned here for the ordering rule: ("yeah" + "oh" x6) x5
        // + "yeah" is ALSO a seven-word block x5. The shortest period that convicts owns the
        // pass, so the "oh" runs go first, the touching "yeah"s go next, and nothing stands.
        var specimen: [TranscribedToken] = []
        for copy in 0..<5 {
            specimen += phrase(["yeah,"] + Array(repeating: "oh", count: 6), times: 1, from: Double(copy) * 3)
        }
        specimen += [token("yeah,", onset: 15)]
        XCTAssertEqual(filtered([specimen]), [])
    }

    func testAPunctuationOnlyTokenInsideAPhraseBreaksThePattern() {
        // The one-word rule's break, kept: a block that folds to nothing anywhere never matches.
        let segment = phrase(["I'm", "gonna", "go", "..."], times: 8, from: 0)
        XCTAssertEqual(filtered([segment]), segment.map(\.text))
    }

    func testThePhraseGuardIsDeterministic() {
        let before = filler(7, "verse")
        let after = filler(3, "next")
        let segments = [
            line(before, from: 1)
                + phrase(["if", "you", "can", "hear", "me", "I'm", "not", "sure"], times: 8, from: 3),
            phrase(["I'm", "gonna", "go"], times: 3, from: 30),
            phrase(["I'm", "gonna", "go"], times: 5, from: 40) + line(after, from: 60),
        ]
        let first = WhisperLyricsEngine.filterArtifacts(segments: segments, audioDuration: 240)
        let second = WhisperLyricsEngine.filterArtifacts(segments: segments, audioDuration: 240)

        XCTAssertEqual(first.map(\.text), before + after)
        XCTAssertEqual(first.map(\.text), second.map(\.text))
        XCTAssertEqual(first.map(\.onsetTime), second.map(\.onsetTime))
        XCTAssertEqual(first.map(\.duration), second.map(\.duration))
        XCTAssertEqual(first.map(\.confidence), second.map(\.confidence))
        XCTAssertEqual(first.map(\.startsSegment), second.map(\.startsSegment))
    }

    func testThePhraseWindowIsSixteenWordsAndTheFloorIsShared() {
        XCTAssertEqual(WhisperLyricsEngine.repetitionPhraseMaxWords, 16)
        // A 17-word block x5 is past the window and stays; a 16-word block x5 goes.
        let sixteen = phrase(filler(16, "w"), times: 5, from: 0)
        let seventeen = phrase(filler(17, "w"), times: 5, from: 0)
        XCTAssertEqual(filtered([sixteen]), [])
        XCTAssertEqual(filtered([seventeen]), seventeen.map(\.text))
    }

    // MARK: - Artifact filter rule 1, sign-off segments (P-2026-09-08-17, 2026-09-09)

    func testAThanksForWatchingSegmentIsDroppedEvenAsTheTakesFirstSegment() {
        // Avercage, Embers, as minted: token 0 of the take at 12.4 s, "Thanks" at 0.07 (under the
        // ghost floor, alive only through the opening-word exemption), "for watching!" at 0.8+.
        let signOff = [token("Thanks", onset: 12.44, duration: 1.4, confidence: 0.07),
                       token("for", onset: 13.84, duration: 0, confidence: 0.89),
                       token("watching!", onset: 13.84, duration: 14.36, confidence: 0.93)]
        // The real opening, 20 s later, with the measured shape of a real first word: weak.
        // (A stand-in line; the sung words stay in the corpus.)
        let verse = [token("the", onset: 32.94, confidence: 0.10), token("verse", onset: 33.2, confidence: 0.9),
                     token("begins", onset: 33.6, confidence: 0.9)]

        let survivors = WhisperLyricsEngine.filterArtifacts(segments: [signOff, verse], audioDuration: 242)

        // The sign-off is gone, and the opening-word exemption went to the first sung word.
        XCTAssertEqual(survivors.map(\.text), ["the", "verse", "begins"])
        XCTAssertEqual(survivors.first?.startsSegment, true)
    }

    func testOnlyTheNamedSignOffsAreDropped() {
        let thankYou = [token("Thank", onset: 20), token("you", onset: 20.3), token("for", onset: 20.6),
                        token("watching.", onset: 20.9)]
        let listening = [token("thanks", onset: 20), token("for", onset: 20.3), token("listening", onset: 20.6)]
        let thanks = [token("Thanks!", onset: 20)]
        let verse = line("the verse begins", from: 33)

        XCTAssertEqual(filtered([thankYou, verse]), ["the", "verse", "begins"])
        XCTAssertEqual(filtered([listening, verse]), ["thanks", "for", "listening", "the", "verse", "begins"])
        XCTAssertEqual(filtered([thanks, verse]), ["Thanks!", "the", "verse", "begins"])
    }

    func testALyricCarryingTheSignOffWordsAmongOthersIsKept() {
        let lyric = line("thanks for watching over me", from: 10)
        let split = [line("thanks for", from: 10), line("watching the stars", from: 11)]

        XCTAssertEqual(filtered([lyric]), lyric.map(\.text))
        XCTAssertEqual(filtered(split), split.flatMap { $0.map(\.text) })
        XCTAssertFalse(WhisperLyricsEngine.isSignOffSegment([]))
    }

    // MARK: - Pinned decode config

    func testPinnedDecodingOptionsMatchTheMeasuredRescueConfig() {
        // The parity-check rescue config (2026-08-07): any drift here is a measured-WER
        // regression, not a style choice. See WhisperLyricsEngine.pinnedDecodingOptions.
        let options = WhisperLyricsEngine.pinnedDecodingOptions()

        XCTAssertEqual(options.language, "en")
        XCTAssertTrue(options.usePrefillPrompt)
        XCTAssertTrue(options.skipSpecialTokens)
        XCTAssertTrue(options.wordTimestamps)
        XCTAssertEqual(options.firstTokenLogProbThreshold, -100)
        XCTAssertEqual(options.suppressTokens, WhisperLyricsEngine.nonSpeechSuppressTokens)
        // The OpenAI 82-token non-speech list + the no_speech token 50362 = 83 entries.
        XCTAssertEqual(WhisperLyricsEngine.nonSpeechSuppressTokens.count, 83)
        XCTAssertTrue(WhisperLyricsEngine.nonSpeechSuppressTokens.contains(50362))
        // NO initial prompt EVER: a title prompt measured a 56.7%-WER repetition catastrophe.
        XCTAssertNil(options.promptTokens)
        XCTAssertNil(options.prefixTokens)
    }

    // MARK: - Warming (LyricsExtractor.prepare / WhisperLyricsEngine.preload)

    /// No configured folder means there is nothing a consumer could preload — the Apple paths
    /// own their own model assets. Must return promptly and never throw.
    func testPrepareWithNoWhisperFolderIsANoOp() async {
        await LyricsExtractor.prepare(configuration: .default)
        await LyricsExtractor.prepare(configuration: LyricsExtractor.Configuration(whisperModelFolder: nil))
    }

    /// FAIL-SOFT: a folder that holds no loadable model must leave warming silent, exactly as an
    /// unloadable folder leaves `transcribe` silently on the Apple path. Warming may never become
    /// a new way for the app to learn about a problem it would otherwise route around.
    func testPrepareWithAnUnloadableFolderStaysSilent() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcc-whisper-warm-\(UUID().uuidString)", isDirectory: true)
        await LyricsExtractor.prepare(configuration: LyricsExtractor.Configuration(whisperModelFolder: missing))
    }

    /// The engine-level door THROWS for the same folder the extractor-level door swallows — a
    /// caller that wants to know can ask. This is what keeps `prepare`'s silence a deliberate
    /// policy choice rather than a missing signal.
    func testPreloadOnAnUnloadableFolderThrows() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcc-whisper-warm-\(UUID().uuidString)", isDirectory: true)
        do {
            try await WhisperLyricsEngine.preload(modelFolder: missing)
            XCTFail("preload should throw for a folder holding no model")
        } catch {
            // Expected — WhisperKit reports the missing model files.
        }
    }

    // MARK: - The recognizer's own segment boundaries (0.1.11)

    /// Whisper decodes in segments and reports where each begins. That boundary is a real signal
    /// about phrasing, and MCC used to drop it when flattening segments into one stream. Now the
    /// first token of each segment carries it.
    func testTheFirstTokenOfEachSegmentIsMarked() {
        let first = [token("Forever", onset: 0.4, confidence: 0.9),
                     token("I", onset: 0.9, confidence: 0.9)]
        let second = [token("Forever", onset: 3.0, confidence: 0.9),
                      token("I", onset: 3.4, confidence: 0.9)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [first, second],
                                                           audioDuration: 60)

        XCTAssertEqual(filtered.map(\.startsSegment), [true, false, true, false])
    }

    /// THE FLAG DESCRIBES THE STREAM THAT IS RETURNED, not the one that went in: if the
    /// segment's original first word was a ghost and got dropped, the flag moves to the word
    /// that IS now first.
    func testTheFlagFollowsTheSurvivingFirstWord() {
        let segment = [token("Forever", onset: 3.0, confidence: 0.9),
                       token("ghost", onset: 3.2, confidence: 0.04),
                       token("I", onset: 3.4, confidence: 0.9)]
        // A first segment exists so the take-opening exemption is spent before this one.
        let opener = [token("start", onset: 0.2, confidence: 0.9)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [opener, segment],
                                                           audioDuration: 60)

        XCTAssertEqual(filtered.map(\.text), ["start", "Forever", "I"])
        XCTAssertEqual(filtered.map(\.startsSegment), [true, true, false])
    }

    /// A dropped caption segment does not leave a stray boundary behind.
    func testADroppedCaptionDoesNotLeaveABoundary() {
        let caption = [token("Music", onset: 0.1, confidence: 0.9)]
        let real = [token("Listen", onset: 4.0, confidence: 0.9),
                    token("to", onset: 4.3, confidence: 0.9)]

        let filtered = WhisperLyricsEngine.filterArtifacts(segments: [caption, real],
                                                           audioDuration: 60)

        XCTAssertEqual(filtered.map(\.text), ["Listen", "to"])
        XCTAssertEqual(filtered.map(\.startsSegment), [true, false])
    }

    /// Existing callers are untouched: the flag defaults to false.
    func testTheFlagDefaultsToFalse() {
        XCTAssertFalse(TranscribedToken(text: "word", onsetTime: 0, duration: 0.3).startsSegment)
    }
}

// MARK: - The coverage gate + crawl containment (2026-08-12: the hour-long listen)

/// Pure tests for the pieces that ended the sparse-audio decode grind and the hallucinated
/// instrumental transcripts (populations measured over the 15-take corpus + wordless stem
/// specimens; see the constants' doc comments).
extension WhisperLyricsEngineTests {

    private func tokensAt(_ count: Int, confidence: Double) -> [TranscribedToken] {
        (0..<count).map {
            TranscribedToken(text: "w\($0)", onsetTime: Double($0), duration: 0.3,
                             confidence: confidence)
        }
    }

    func testSparseWeakTranscriptOnALongTakeIsGated() {
        // The measured hallucination shape: 13 words over 35 s at mean 0.43 (the clean
        // instrumental stem specimen). Both clauses fail → gated.
        let junk = tokensAt(13, confidence: 0.43)
        XCTAssertFalse(WhisperLyricsEngine.passesCoverageGate(junk, audioDuration: 35.4))
    }

    func testDenseSingingPassesOnRate() {
        // Broken Man 2026-08-11: 48 wpm at 0.76 — passes both clauses.
        let dense = tokensAt(192, confidence: 0.76)
        XCTAssertTrue(WhisperLyricsEngine.passesCoverageGate(dense, audioDuration: 238.1))
    }

    func testSparseButConfidentWordsPassOnConfidence() {
        // Beauty All Around: 21.4 wpm (under the rate clause) at 0.82 — the confidence
        // clause alone keeps a genuine sparse lyric.
        let sparse = tokensAt(37, confidence: 0.82)
        XCTAssertTrue(WhisperLyricsEngine.passesCoverageGate(sparse, audioDuration: 103.8))
    }

    func testShortTakesAreNeverGated() {
        // Under the duration floor there is not enough audio to judge coverage honestly.
        let few = tokensAt(3, confidence: 0.2)
        XCTAssertTrue(WhisperLyricsEngine.passesCoverageGate(few, audioDuration: 20))
    }

    func testEmptyAndConfidencelessTranscriptsPassVacuously() {
        XCTAssertTrue(WhisperLyricsEngine.passesCoverageGate([], audioDuration: 120))
        let noConf = (0..<5).map {
            TranscribedToken(text: "w\($0)", onsetTime: Double($0), duration: 0.3, confidence: nil)
        }
        XCTAssertTrue(WhisperLyricsEngine.passesCoverageGate(noConf, audioDuration: 120))
    }

    func testTokenOffsetRestoresFileAbsoluteTime() {
        // The sliced decode hands each slice to WhisperKit separately; the mapper puts the
        // slice's start back so downstream timing (charts, line breaks) stays file-absolute.
        let words = [WordTiming(word: " home", tokens: [], start: 2.0, end: 2.5, probability: 0.9)]
        let mapped = WhisperLyricsEngine.tokens(fromWords: words, offsetBy: 60)
        XCTAssertEqual(mapped.first?.onsetTime, 62.0)
        XCTAssertEqual(mapped.first?.duration ?? -1, 0.5, accuracy: 0.0001)
    }

    // MARK: - The slice decode ledger (the 2026-08-12 window cap)

    /// Window transitions are detected by the progress token count DROPPING — WhisperKit
    /// accumulates tokens within a window and resets for the next. Rising counts are one window.
    func testWindowTransitionsAreCountedByTokenReset() {
        let ledger = WhisperLyricsEngine.SliceDecodeLedger(tokenBudget: 1000, windowCap: 8)
        var breaches = 0
        ledger.onWindowCapBreached = { breaches += 1 }

        // Window 1: tokens 1…4. Window 2: reset to 1, then 2. Window 3: reset to 1.
        for count in [1, 2, 3, 4, 1, 2, 1] { _ = ledger.note(tokenCount: count) }

        XCTAssertEqual(breaches, 0, "three windows is a healthy slice under a cap of eight")
    }

    /// The breach fires exactly once, at the first window past the cap — not on every window
    /// after it. One cancel is all the decode task needs.
    func testTheWindowCapBreachFiresExactlyOnce() {
        let ledger = WhisperLyricsEngine.SliceDecodeLedger(tokenBudget: 1000, windowCap: 2)
        var breaches = 0
        ledger.onWindowCapBreached = { breaches += 1 }

        // Five one-token windows: every count of 1 is a reset, so five transitions.
        for _ in 0..<5 { _ = ledger.note(tokenCount: 1) }

        XCTAssertEqual(breaches, 1)
    }

    /// The handler is installed AFTER the decode task exists, so a breach that lands in that
    /// gap must fire the moment the handler arrives — a crawl must never slip through the
    /// installation race.
    func testABreachBeforeTheHandlerInstallsFiresOnInstall() {
        let ledger = WhisperLyricsEngine.SliceDecodeLedger(tokenBudget: 1000, windowCap: 1)
        for _ in 0..<3 { _ = ledger.note(tokenCount: 1) }   // breach with no handler yet

        var breaches = 0
        ledger.onWindowCapBreached = { breaches += 1 }

        XCTAssertEqual(breaches, 1, "the stored breach fires on installation")
    }

    /// The token budget's early-stop verdict is unchanged by the ledger rebuild: true while
    /// budget remains, false once spent — the pre-cap behavior, preserved.
    func testTheTokenBudgetVerdictStillEarlyStops() {
        let ledger = WhisperLyricsEngine.SliceDecodeLedger(tokenBudget: 3, windowCap: 8)

        XCTAssertTrue(ledger.note(tokenCount: 1))
        XCTAssertTrue(ledger.note(tokenCount: 2))
        XCTAssertFalse(ledger.note(tokenCount: 3), "the third spend exhausts a budget of three")
        XCTAssertFalse(ledger.note(tokenCount: 4), "and it stays spent")
    }

    /// A dense sung slice — one window, many tokens — never approaches the cap, whatever its
    /// length in tokens. The cap is about window COUNT, not token count.
    func testAHealthySliceNeverBreaches() {
        let ledger = WhisperLyricsEngine.SliceDecodeLedger(tokenBudget: 1000, windowCap: 8)
        var breaches = 0
        ledger.onWindowCapBreached = { breaches += 1 }

        for count in 1...300 { _ = ledger.note(tokenCount: count) }

        XCTAssertEqual(breaches, 0)
    }
}

// MARK: - The silent-slice retry (0.1.18, 2026-09-07)

extension WhisperLyricsEngineTests {
    /// A slice that decodes to nothing is retried with its window shifted forward, and the retry's
    /// words are kept only where the first decode was asked to look. Everything past that boundary
    /// is the next slice's audio, which decodes it itself; keeping both copies would say each of
    /// those words twice.
    func testTheRetryKeepsOnlyTheWordsInsideTheSliceItRetried() {
        let spanEnd = 30.0
        let tokens = [
            TranscribedToken(text: "long", onsetTime: 9.8, duration: 0.3, confidence: 0.75),
            TranscribedToken(text: "ago", onsetTime: 11.0, duration: 0.3, confidence: 1.0),
            TranscribedToken(text: "light", onsetTime: 27.8, duration: 0.3, confidence: 0.93),
            TranscribedToken(text: "never", onsetTime: 31.7, duration: 0.3, confidence: 0.5),
            TranscribedToken(text: "knew", onsetTime: 32.5, duration: 0.3, confidence: 1.0),
        ]
        let kept = WhisperLyricsEngine.tokensBeginningBefore(spanEnd, in: tokens)
        XCTAssertEqual(kept.map(\.text), ["long", "ago", "light"],
                       "The opening comes back; the words past the slice belong to the next slice")
    }

    func testTheRetrySpanFilterIsEmptyWhenEverythingLandsPastTheBoundary() {
        let tokens = [TranscribedToken(text: "never", onsetTime: 31.7, duration: 0.3, confidence: 0.5)]
        XCTAssertTrue(WhisperLyricsEngine.tokensBeginningBefore(30.0, in: tokens).isEmpty,
                      "Nothing inside the span means the slice stands wordless, as it did before")
    }

    /// The shift is a quarter of the 30 s window: far enough to move a sung entrance off the
    /// boundary that swallowed it (measured at 3 s on Shadows), short enough that the retry still
    /// covers most of the span it was asked about.
    func testTheRetryShiftIsAQuarterOfTheWindow() {
        XCTAssertEqual(WhisperLyricsEngine.silentSliceRetryShift, 7.5)
        XCTAssertEqual(WhisperLyricsEngine.silentSliceRetryFrames, 120_000,
                       "7.5 s at WhisperKit's 16 kHz")
    }
}

// MARK: - A cancelled or timed-out listen stops decoding (P-2026-09-08-12, 2026-09-08)

/// Songcatcher cancels its listen task when the listen's timeout fires (max(300 s, 4 x the
/// take's duration)) or when the listen is cancelled outright. Before this change the slice loop
/// never looked at the calling task and each slice's decode ran in an unstructured Task that an
/// outer cancel could not reach, so the decode ground on to the end of the take. The per-slice
/// cancel (ledger window cap, wall-clock watchdog) is a bound on ONE slice and is untouched.
extension WhisperLyricsEngineTests {
    /// A model folder that does not exist. If the engine ever reaches the model it fails with
    /// WhisperKit's own error, never a CancellationError, so the assertions below can tell "the
    /// cancel was honoured first" apart from "the call failed for some other reason".
    private static func missingModelFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mcc-whisper-cancel-\(UUID().uuidString)", isDirectory: true)
    }

    /// Run `body` on a task that is ALREADY cancelled when the body starts: the task yields until
    /// the cancel has landed, so the body never races `cancel()`.
    private func onAnAlreadyCancelledTask<T>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        let task = Task<T, Error> {
            while !Task.isCancelled { await Task.yield() }
            return try await body()
        }
        task.cancel()
        return await task.result
    }

    /// The engine door: a cancelled caller gets CancellationError before the model is touched.
    func testTranscribeFromACancelledTaskThrowsCancellationBeforeTouchingTheModel() async {
        let silence = [Float](repeating: 0, count: 16_000)
        let folder = Self.missingModelFolder()

        let outcome = await onAnAlreadyCancelledTask {
            try await WhisperLyricsEngine.transcribe(buffer: silence, sampleRate: 16_000,
                                                     modelFolder: folder)
        }

        switch outcome {
        case .success(let tokens):
            XCTFail("a cancelled caller must not get a transcript (got \(tokens.count) tokens)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                          "expected CancellationError before the model is touched, got \(error)")
        }
    }

    /// The public door: `LyricsExtractor.transcribe` swallows every Whisper failure and falls
    /// back to Apple, and a cancel is not a failure. It must reach the caller as
    /// CancellationError, not start a second decode on the Apple path.
    func testTheExtractorRethrowsACancelInsteadOfFallingBackToApple() async {
        let silence = [Float](repeating: 0, count: 16_000)
        let configuration = LyricsExtractor.Configuration(whisperModelFolder: Self.missingModelFolder())

        let outcome = await onAnAlreadyCancelledTask {
            try await LyricsExtractor.transcribe(buffer: silence, sampleRate: 16_000,
                                                 locale: "en-US", configuration: configuration)
        }

        switch outcome {
        case .success(let tokens):
            XCTFail("a cancelled caller must not get a transcript (got \(tokens.count) tokens)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                          "expected the cancel to reach the caller, got \(error)")
        }
    }

    /// MODEL-BACKED, gated like the integration tests: with a real model on disk, a transcribe
    /// over a long buffer that is cancelled mid-decode throws CancellationError promptly (the
    /// cancel is forwarded into the running slice, so it stops within one Whisper window) rather
    /// than decoding the remaining slices first. Twenty minutes of low-level noise is forty
    /// slices, far more than twenty seconds of decode on any host.
    func testACancelledTranscribeStopsWithinOneWindow() async throws {
        guard let modelDir = ProcessInfo.processInfo.environment["MCC_WHISPER_MODEL_DIR"] else {
            throw XCTSkip("MCC_WHISPER_MODEL_DIR not set: skipping the model-backed cancellation test.")
        }
        let folder = URL(fileURLWithPath: modelDir, isDirectory: true)
        // Pay the model load up front so the clock below measures the decode loop, not the load.
        try await WhisperLyricsEngine.preload(modelFolder: folder)

        let oneSecond = (0..<16_000).map { _ in Float.random(in: -0.01...0.01) }
        let noise = Array([[Float]](repeating: oneSecond, count: 20 * 60).joined())

        let listen = Task {
            try await WhisperLyricsEngine.transcribe(buffer: noise, sampleRate: 16_000,
                                                     modelFolder: folder)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let cancelledAt = Date()
        listen.cancel()
        let outcome = await listen.result
        let secondsAfterCancel = Date().timeIntervalSince(cancelledAt)

        switch outcome {
        case .success(let tokens):
            XCTFail("a cancelled listen must not finish the take (returned \(tokens.count) tokens "
                    + "\(String(format: "%.1f", secondsAfterCancel)) s after the cancel)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(secondsAfterCancel, 20,
                          "the cancel must end the decode within one window, not at the take's end")
        print("cancelled transcribe returned \(String(format: "%.2f", secondsAfterCancel)) s after the cancel")
    }
}
