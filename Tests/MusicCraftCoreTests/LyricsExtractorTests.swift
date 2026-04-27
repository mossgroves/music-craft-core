import XCTest
@testable import MusicCraftCore

final class LyricsExtractorTests: XCTestCase {

    func testTranscribedTokenConstruction() {
        // Structural test: validates TranscribedToken struct construction.
        // Real-audio transcription deferred to 0.0.9.1 real-audio fixtures.
        let token = TranscribedToken(
            text: "hello",
            onsetTime: 0.0,
            duration: 0.5,
            confidence: 0.95
        )

        XCTAssertEqual(token.text, "hello")
        XCTAssertEqual(token.onsetTime, 0.0)
        XCTAssertEqual(token.duration, 0.5)
        XCTAssertEqual(token.confidence, 0.95)
        XCTAssertEqual(token.offsetTime, 0.5)
    }

    func testTranscribedTokenConfidenceOptional() {
        // Structural test: confidence field is optional (iOS 17 SFSpeechRecognizer has no per-token confidence).
        // Real-audio accuracy deferred to 0.0.9.1.
        let token = TranscribedToken(
            text: "world",
            onsetTime: 0.5,
            duration: 0.4
        )

        XCTAssertEqual(token.text, "world")
        XCTAssertNil(token.confidence)
    }

    func testTranscribedTokenEquatable() {
        // Structural test: tokens are comparable for testing.
        let token1 = TranscribedToken(text: "test", onsetTime: 0.0, duration: 0.5)
        let token2 = TranscribedToken(text: "test", onsetTime: 0.0, duration: 0.5)
        let token3 = TranscribedToken(text: "other", onsetTime: 0.0, duration: 0.5)

        XCTAssertEqual(token1, token2)
        XCTAssertNotEqual(token1, token3)
    }

    func testTranscribedTokenHashable() {
        // Structural test: tokens can be used in sets and dictionaries.
        let token1 = TranscribedToken(text: "test", onsetTime: 0.0, duration: 0.5)
        let token2 = TranscribedToken(text: "test", onsetTime: 0.0, duration: 0.5)

        var set: Set<TranscribedToken> = [token1]
        set.insert(token2)

        XCTAssertEqual(set.count, 1)
    }

    func testTranscribedTokenSendable() {
        // Structural test: tokens are Sendable (can cross async boundaries).
        // Compile-time check via type system; runtime validation here.
        let token = TranscribedToken(text: "test", onsetTime: 0.0, duration: 0.5)
        let _: any Sendable = token
    }

    func testLyricsExtractorConfigurationConstruction() {
        // Structural test: Configuration struct can be constructed with defaults.
        let config = LyricsExtractor.Configuration()

        XCTAssertTrue(config.waitForFinalResult)
        XCTAssertTrue(config.includeConfidence)
    }

    func testLyricsExtractorConfigurationCustom() {
        // Structural test: Configuration can be customized.
        let config = LyricsExtractor.Configuration(waitForFinalResult: false, includeConfidence: false)

        XCTAssertFalse(config.waitForFinalResult)
        XCTAssertFalse(config.includeConfidence)
    }

    func testLyricsExtractorConfigurationDefault() {
        // Structural test: Configuration.default matches expected defaults.
        let config = LyricsExtractor.Configuration.default

        XCTAssertTrue(config.waitForFinalResult)
        XCTAssertTrue(config.includeConfidence)
    }

    func testLyricsExtractorConfigurationEquatable() {
        // Structural test: configurations are comparable.
        let config1 = LyricsExtractor.Configuration()
        let config2 = LyricsExtractor.Configuration()
        let config3 = LyricsExtractor.Configuration(waitForFinalResult: false)

        XCTAssertEqual(config1, config2)
        XCTAssertNotEqual(config1, config3)
    }

    func testSpeechFrameworkErrorFrameworkUnavailable() {
        // Structural test: framework unavailable error can be constructed and compared.
        let error1 = LyricsExtractor.SpeechFrameworkError.frameworkUnavailable
        let error2 = LyricsExtractor.SpeechFrameworkError.frameworkUnavailable

        XCTAssertEqual(error1, error2)
    }

    func testSpeechFrameworkErrorRecognitionFailed() {
        // Structural test: recognition failed error wraps error message.
        let error = LyricsExtractor.SpeechFrameworkError.recognitionFailed("mock error")

        if case .recognitionFailed(let message) = error {
            XCTAssertEqual(message, "mock error")
        } else {
            XCTFail("Expected recognitionFailed case")
        }
    }

    func testSpeechFrameworkErrorLocaleUnsupported() {
        // Structural test: locale unsupported error captures locale.
        let error = LyricsExtractor.SpeechFrameworkError.localeUnsupported("zh-CN")

        if case .localeUnsupported(let locale) = error {
            XCTAssertEqual(locale, "zh-CN")
        } else {
            XCTFail("Expected localeUnsupported case")
        }
    }

    func testSpeechFrameworkErrorPermissionDenied() {
        // Structural test: permission denied error.
        let error = LyricsExtractor.SpeechFrameworkError.permissionDenied

        if case .permissionDenied = error {
            // Test passes
        } else {
            XCTFail("Expected permissionDenied case")
        }
    }

    func testTranscribedTokenOffsettimeComputation() {
        // Structural test: offsetTime computed property is correct.
        let token = TranscribedToken(
            text: "test",
            onsetTime: 1.5,
            duration: 0.3
        )

        XCTAssertEqual(token.offsetTime, 1.8, accuracy: 0.001)
    }
}
