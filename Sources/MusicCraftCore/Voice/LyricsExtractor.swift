import Foundation
import Speech

/// On-device lyric transcription wrapper around Apple's Speech framework.
/// Produces timestamped word-level tokens for alignment with chord and melody timelines.
///
/// Uses SFSpeechRecognizer (iOS 17+ baseline). iOS 26+ can optionally configure
/// SpeechAnalyzer behavior via Configuration (forward-compatible; 0.0.10 will implement iOS 26 path).
public enum LyricsExtractor {
    /// Transcribe speech from an audio buffer, producing timestamped word-level tokens.
    /// Async; wraps Apple's Speech framework (SFSpeechRecognizer or SpeechAnalyzer).
    /// Uses system-managed language models; no model bundling or management by MCC.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000)
    ///   - locale: BCP 47 language tag (e.g., "en-US", "es-ES"). Defaults to device locale.
    ///   - configuration: Optional tuning for speech detection (SpeechAnalyzer only; SFSpeechRecognizer ignores).
    /// - Returns: Array of timestamped tokens, or error if Speech framework is unavailable or transcription fails
    /// - Throws: SpeechFrameworkError wrapping Apple errors
    public static func transcribe(
        buffer: [Float],
        sampleRate: Double,
        locale: String? = nil,
        configuration: Configuration? = nil
    ) async throws -> [TranscribedToken] {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale ?? Locale.current.language.languageCode?.identifier ?? "en-US"))

        guard let recognizer else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        guard recognizer.isAvailable else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        return try await transcribeWithSFSpeechRecognizer(buffer: buffer, sampleRate: sampleRate, recognizer: recognizer, configuration: configuration)
    }

    private static func transcribeWithSFSpeechRecognizer(
        buffer: [Float],
        sampleRate: Double,
        recognizer: SFSpeechRecognizer,
        configuration: Configuration?
    ) async throws -> [TranscribedToken] {
        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(buffer.count)) else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        audioBuffer.floatChannelData?[0].update(from: buffer, count: buffer.count)
        audioBuffer.frameLength = AVAudioFrameCount(buffer.count)

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            request.append(audioBuffer)
            request.endAudio()

            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: SpeechFrameworkError.recognitionFailed(error.localizedDescription))
                    return
                }

                guard let result = result else {
                    continuation.resume(returning: [])
                    return
                }

                let tokens = result.transcriptions.flatMap { transcription in
                    transcription.segments.map { segment in
                        TranscribedToken(
                            text: segment.substring,
                            onsetTime: segment.timestamp,
                            duration: segment.duration,
                            confidence: nil
                        )
                    }
                }

                continuation.resume(returning: tokens)
            }
        }
    }

    /// Configuration for iOS 26+ SpeechAnalyzer. Ignored on iOS 17 SFSpeechRecognizer (forward-compatible).
    public struct Configuration: Equatable, Hashable, Sendable {
        /// Defer final results until the buffer ends, rather than returning partial hypotheses. Default: true.
        public let waitForFinalResult: Bool

        /// Include confidence scores for each token. Default: true.
        /// Only applicable to iOS 26+ SpeechAnalyzer; iOS 17 SFSpeechRecognizer always returns nil.
        public let includeConfidence: Bool

        public init(waitForFinalResult: Bool = true, includeConfidence: Bool = true) {
            self.waitForFinalResult = waitForFinalResult
            self.includeConfidence = includeConfidence
        }

        public static let `default` = Configuration()
    }

    /// Errors from Speech framework, wrapped for public API consumption.
    public enum SpeechFrameworkError: Error, Equatable, Sendable {
        /// Speech framework not available on this device or iOS version.
        case frameworkUnavailable

        /// Recognition failed with wrapped error message.
        case recognitionFailed(String)

        /// Requested locale not supported by Speech framework.
        case localeUnsupported(String)

        /// User denied microphone or speech recognition permission.
        /// Consumer handles this via UIApplicationDelegate privacy request.
        case permissionDenied
    }
}
