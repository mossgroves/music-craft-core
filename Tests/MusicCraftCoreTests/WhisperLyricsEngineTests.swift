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
}
