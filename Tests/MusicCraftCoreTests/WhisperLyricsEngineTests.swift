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
