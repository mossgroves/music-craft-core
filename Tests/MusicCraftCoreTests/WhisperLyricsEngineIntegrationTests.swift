import AVFoundation
import XCTest
@testable import MusicCraftCore

/// Real-inference integration test for the Whisper lyric path. Gated behind environment
/// variables so the normal suite stays model-free and fast:
///
///   MCC_WHISPER_MODEL_DIR   — folder holding a WhisperKit CoreML model (openai_whisper-small),
///                             tokenizer resolvable locally (see Configuration.whisperModelFolder).
///   MCC_WHISPER_AUDIO_FILE  — any short audio file with sung or spoken words (wav/m4a/...).
///
/// Example (paths from the 2026-08-07 validation sessions on this Mac):
///   MCC_WHISPER_MODEL_DIR=".../whisperkit-parity/models/models/argmaxinc/whisperkit-coreml/openai_whisper-small" \
///   MCC_WHISPER_AUDIO_FILE=".../isolation-spike/original-excerpt-1m00.wav" \
///   swift test --filter WhisperLyricsEngineIntegrationTests
final class WhisperLyricsEngineIntegrationTests: XCTestCase {
    /// End-to-end through the PUBLIC surface: LyricsExtractor.transcribe with a
    /// whisperModelFolder must produce non-empty, time-ordered, confidence-carrying tokens
    /// from real audio — proof the engine loads the model, decodes with the pinned config,
    /// and maps WordTimings, without ever hitting the Apple fallback.
    func testWhisperEngineTranscribesRealAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelDir = environment["MCC_WHISPER_MODEL_DIR"] else {
            throw XCTSkip("MCC_WHISPER_MODEL_DIR not set — skipping real-inference test.")
        }
        guard let audioPath = environment["MCC_WHISPER_AUDIO_FILE"] else {
            throw XCTSkip("MCC_WHISPER_AUDIO_FILE not set — skipping real-inference test.")
        }

        let (samples, sampleRate) = try Self.loadMono(URL(fileURLWithPath: audioPath))
        let audioDuration = Double(samples.count) / sampleRate

        // Call the ENGINE directly (not LyricsExtractor) so a Whisper failure surfaces as a
        // test failure instead of being silently recovered by the Apple fallback.
        let tokens = try await WhisperLyricsEngine.transcribe(
            buffer: samples,
            sampleRate: sampleRate,
            modelFolder: URL(fileURLWithPath: modelDir, isDirectory: true)
        )

        XCTAssertFalse(tokens.isEmpty, "Expected words from \(audioPath) (\(audioDuration)s)")

        for token in tokens {
            XCTAssertFalse(token.text.isEmpty)
            XCTAssertGreaterThanOrEqual(token.onsetTime, 0)
            XCTAssertLessThanOrEqual(
                token.onsetTime, audioDuration + 1.0,
                "Token '\(token.text)' onsets past the end of the audio"
            )
            XCTAssertGreaterThanOrEqual(token.duration, 0)
            let confidence = try XCTUnwrap(
                token.confidence,
                "Whisper tokens must carry word probability as confidence"
            )
            XCTAssertGreaterThanOrEqual(
                confidence, WhisperLyricsEngine.ghostConfidenceFloor,
                "Filter must have dropped sub-floor tokens"
            )
        }

        // Word onsets are file-absolute and non-decreasing (seek offsets applied per window).
        let onsets = tokens.map(\.onsetTime)
        XCTAssertEqual(onsets, onsets.sorted(), "Token onsets must be non-decreasing")

        print("WhisperLyricsEngine: \(tokens.count) tokens from \(String(format: "%.1f", audioDuration))s")
        print(tokens.map(\.text).joined(separator: " "))
    }

    /// Load any AVFoundation-readable audio file as mono Float32 at its native sample rate,
    /// averaging channels (the spike wavs are stereo; LyricsExtractor takes mono).
    private static func loadMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "WhisperIntegrationTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate a read buffer for \(url.path)",
            ])
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "WhisperIntegrationTest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No float channel data in \(url.path)",
            ])
        }

        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let source = channelData[channel]
            for frame in 0..<frames {
                mono[frame] += source[frame]
            }
        }
        if channels > 1 {
            let scale = 1.0 / Float(channels)
            for frame in 0..<frames {
                mono[frame] *= scale
            }
        }
        return (mono, format.sampleRate)
    }
}
