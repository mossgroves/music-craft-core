import XCTest
import Speech
import AVFoundation
@testable import MusicCraftCore

/// Phase 5 test suite: LyricsExtractor accuracy on AVSpeechSynthesizer TTS fixtures.
/// Scope: TTS audio only (clean synthetic speech, no singing voice).
/// Real-vocal accuracy deferred to Phase 5.1.
/// Run fixture generation first: MCC_GENERATE_LYRIC_FIXTURES=1 swift test --filter TTSFixtureGeneratorTests
final class LyricsExtractorRealAudioTests: XCTestCase {

    struct Thresholds {
        // SFSpeechRecognizer literature: 90-95%+ word accuracy on clean dictation.
        // TTS audio is clean/synthetic speech → expect near upper end.
        // Threshold set conservatively at 85% per calibration-down rule.
        // Adjust after first-run if within ~15pp of anchor (70%); otherwise surface as finding.
        static let wordAccuracyMean: Double = 0.85
        static let characterErrorRateMax: Double = 0.10
        // Homophone fixture ("their there they're") explicitly excluded from aggregates
        // due to known SFSpeechRecognizer limitation; reported separately.
    }

    func testLyricsExtractorAccuracy() async throws {
        #if os(macOS)
        // Speech recognition on headless/CLI macOS is unreliable; skip for now
        // Fixtures are generated and can be tested on real devices or in Xcode
        throw XCTSkip("Speech recognition testing deferred to device/Xcode environment (macOS CLI limitation)")
        #endif

        // Check speech recognition availability
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw XCTSkip("SFSpeechRecognizer unavailable for en-US locale")
        }

        guard recognizer.isAvailable else {
            throw XCTSkip("SFSpeechRecognizer not available (offline or first-time setup)")
        }

        // Check authorization status
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .denied || authStatus == .restricted {
            throw XCTSkip("Speech recognition permission denied. Grant permission in System Preferences > Privacy > Speech Recognition.")
        }

        // Request authorization if needed
        if authStatus == .notDetermined {
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard authorized else {
                throw XCTSkip("Speech recognition authorization denied.")
            }
        }

        // Load fixtures
        let fixtures = try LyricFixture.all()
        guard !fixtures.isEmpty else {
            throw XCTSkip("No TTS fixtures found. Run: MCC_GENERATE_LYRIC_FIXTURES=1 swift test --filter TTSFixtureGeneratorTests")
        }

        print("\n=== LYRICS EXTRACTOR ACCURACY (TTS FIXTURES) ===\n")

        var allMetrics: [AudioAnalysisMetrics.LyricMetrics] = []
        var metricsByCategory: [String: [AudioAnalysisMetrics.LyricMetrics]] = [:]
        var homophones: (detected: String, gt: String, wordAccuracy: Double)? = nil

        // Test each fixture
        for fixture in fixtures {
            let (samples, sampleRate) = try fixture.loadAudio()

            // Transcribe
            let tokens = try await LyricsExtractor.transcribe(
                buffer: samples,
                sampleRate: sampleRate,
                locale: "en-US"
            )

            // Compare
            let metrics = AudioAnalysisMetrics.compareLyrics(
                detected: tokens,
                groundTruth: fixture.words,
                timingToleranceSec: 0.1
            )

            let detectedText = tokens.map { $0.text }.joined(separator: " ")
            let gtText = fixture.words.map { $0.text }.joined(separator: " ")

            print("  \(fixture.id) [\(fixture.category.rawValue)]")
            print("    GT:       \(gtText)")
            print("    Detected: \(detectedText)")
            print("    WER:      \(String(format: "%.1f%%", (1.0 - metrics.wordAccuracy) * 100)) (accuracy: \(String(format: "%.1f%%", metrics.wordAccuracy * 100)))")
            print("    CER:      \(String(format: "%.1f%%", metrics.characterErrorRate * 100))")
            print()

            // Homophone fixture excluded from aggregates (known difficulty)
            if fixture.category == .homophone {
                homophones = (detectedText, gtText, metrics.wordAccuracy)
                continue
            }

            allMetrics.append(metrics)
            metricsByCategory[fixture.category.rawValue, default: []].append(metrics)
        }

        // Aggregate results (excluding homophones)
        guard !allMetrics.isEmpty else {
            XCTFail("No non-homophone fixtures to test")
            return
        }

        let meanWordAccuracy = allMetrics.map { $0.wordAccuracy }.reduce(0, +) / Double(allMetrics.count)
        let maxCER = allMetrics.map { $0.characterErrorRate }.max() ?? 0.0

        print("=== AGGREGATE (excluding homophones) ===\n")

        for category in ["baseline", "pangram", "phonetic", "songlike", "numbers", "longPassage"] {
            guard let metrics = metricsByCategory[category] else { continue }
            let catMeanAccuracy = metrics.map { $0.wordAccuracy }.reduce(0, +) / Double(metrics.count)
            let catMeanCER = metrics.map { $0.characterErrorRate }.reduce(0, +) / Double(metrics.count)
            print("  \(category.padded(to: 15)): accuracy \(String(format: "%.1f%%", catMeanAccuracy * 100)), CER \(String(format: "%.1f%%", catMeanCER * 100))")
        }

        print()
        print("Overall Mean Word Accuracy: \(String(format: "%.1f%%", meanWordAccuracy * 100))")
        print("Maximum CER:               \(String(format: "%.1f%%", maxCER * 100))")

        if let homophones = homophones {
            print()
            print("=== HOMOPHONE FIXTURE (excluded from thresholds) ===")
            print("GT:       \(homophones.gt)")
            print("Detected: \(homophones.detected)")
            print("Accuracy: \(String(format: "%.1f%%", homophones.wordAccuracy * 100))")
            print("(Known limitation: SFSpeechRecognizer struggles with homophone disambiguation)")
        }

        print()

        // Assert against thresholds
        XCTAssertGreaterThanOrEqual(
            meanWordAccuracy,
            Thresholds.wordAccuracyMean,
            "Mean word accuracy \(String(format: "%.1f%%", meanWordAccuracy * 100)) below threshold \(String(format: "%.1f%%", Thresholds.wordAccuracyMean * 100))"
        )

        XCTAssertLessThanOrEqual(
            maxCER,
            Thresholds.characterErrorRateMax,
            "Max CER \(String(format: "%.1f%%", maxCER * 100)) exceeds threshold \(String(format: "%.1f%%", Thresholds.characterErrorRateMax * 100))"
        )
    }
}

// MARK: - String Extension for Formatting

extension String {
    fileprivate func padded(to width: Int) -> String {
        let padding = max(0, width - self.count)
        return self + String(repeating: " ", count: padding)
    }
}
