import Foundation
import Speech
import AVFAudio
import CoreMedia

/// On-device lyric transcription wrapper. Produces timestamped word-level tokens for alignment
/// with chord and melody timelines.
///
/// Engine order (Sanctuary BACKLOG "Lyric transcription", GO 2026-08-07):
/// 1. **WhisperLyricsEngine** (WhisperKit CoreML, whisper-small) — only when the consumer
///    provides `Configuration.whisperModelFolder` AND the request is English (the pinned decode
///    config was measured English-only). The quality path for SUNG material.
/// 2. **Apple Speech** — the shipping fallback, taken when no model folder is set, the folder
///    doesn't hold a loadable model, or the Whisper decode throws. iOS 26+ uses the modern
///    **SpeechAnalyzer / SpeechTranscriber** path (per-word timing from the time-indexed result
///    attributes, optional per-token confidence, on-device model asset installed on demand).
///    iOS 17–25 — and any iOS 26 failure — use **SFSpeechRecognizer**, the fallback floor.
///    The Apple paths use system-managed language models; no model bundling by MCC.
///
/// Whisper model MANAGEMENT (download, placement, eviction) is the consuming app's job; MCC
/// only loads the folder it is handed. `transcribe(...)`'s signature is unchanged across paths.
public enum LyricsExtractor {
    /// Transcribe sung or spoken words from an audio buffer, producing timestamped word-level tokens.
    /// Async; Whisper (WhisperKit) when `configuration.whisperModelFolder` is set and usable,
    /// otherwise Apple's Speech framework (SpeechAnalyzer on iOS 26+, else SFSpeechRecognizer).
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples. For sung material feed the FULL MIX, never an
    ///     isolated vocal stem (stem measured worse — BACKLOG A/B, 2026-08-07).
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000)
    ///   - locale: BCP 47 language tag (e.g., "en-US", "es-ES"). Defaults to device locale.
    ///   - configuration: Whisper model folder + SpeechAnalyzer tuning (SFSpeechRecognizer ignores).
    /// - Returns: Array of timestamped tokens, or error if Speech framework is unavailable or transcription fails
    /// - Throws: SpeechFrameworkError wrapping Apple errors
    public static func transcribe(
        buffer: [Float],
        sampleRate: Double,
        locale: String? = nil,
        configuration: Configuration? = nil
    ) async throws -> [TranscribedToken] {
        let localeIdentifier = locale ?? Locale.current.language.languageCode?.identifier ?? "en-US"

        // Whisper-first when a model folder is provided. English-gated: the pinned decode config
        // hard-codes language "en" (measured; see WhisperLyricsEngine) — a non-English request
        // must not be silently decoded as English, so it goes straight to the Apple path.
        // ANY Whisper failure (unloadable folder, missing tokenizer, decode error) falls through
        // to the Apple path below, which ships unchanged as the fallback floor.
        if let modelFolder = configuration?.whisperModelFolder,
           localeIdentifier.lowercased().hasPrefix("en") {
            do {
                return try await WhisperLyricsEngine.transcribe(
                    buffer: buffer,
                    sampleRate: sampleRate,
                    modelFolder: modelFolder
                )
            } catch {
                // Deliberately swallowed: the Apple path is the documented recovery.
            }
        }

        // iOS 26+: try the modern SpeechAnalyzer path; on any failure (model asset can't be installed,
        // transcription throws) fall back to SFSpeechRecognizer. iOS 17–25: SFSpeechRecognizer directly.
        if #available(iOS 26, macOS 26, *) {
            do {
                return try await transcribeWithSpeechAnalyzer(
                    buffer: buffer,
                    sampleRate: sampleRate,
                    locale: Locale(identifier: localeIdentifier),
                    configuration: configuration ?? .default
                )
            } catch {
                return try await transcribeViaSFSpeechRecognizer(
                    buffer: buffer, sampleRate: sampleRate, localeIdentifier: localeIdentifier, configuration: configuration
                )
            }
        } else {
            return try await transcribeViaSFSpeechRecognizer(
                buffer: buffer, sampleRate: sampleRate, localeIdentifier: localeIdentifier, configuration: configuration
            )
        }
    }

    /// SFSpeechRecognizer path (iOS 17+ baseline, and the iOS 26 fallback floor). Builds the recognizer
    /// and checks availability, then runs the recognition below — the recognition itself is unchanged.
    private static func transcribeViaSFSpeechRecognizer(
        buffer: [Float],
        sampleRate: Double,
        localeIdentifier: String,
        configuration: Configuration?
    ) async throws -> [TranscribedToken] {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))

        guard let recognizer else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        guard recognizer.isAvailable else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        return try await transcribeWithSFSpeechRecognizer(buffer: buffer, sampleRate: sampleRate, recognizer: recognizer, configuration: configuration)
    }

    /// Chunk size for streaming append to SFSpeechAudioBufferRecognitionRequest.
    /// One-second chunks keep the recognizer's stream engaged on long clips; values
    /// between 0.5s and 2.0s are equivalent in observed behavior.
    private static let chunkSeconds: Double = 1.0

    private static func transcribeWithSFSpeechRecognizer(
        buffer: [Float],
        sampleRate: Double,
        recognizer: SFSpeechRecognizer,
        configuration: Configuration?
    ) async throws -> [TranscribedToken] {
        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw SpeechFrameworkError.frameworkUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false

            let chunkFrames = max(1, Int(chunkSeconds * sampleRate))
            var offset = 0
            while offset < buffer.count {
                let end = min(offset + chunkFrames, buffer.count)
                let frameCount = end - offset

                guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                    continuation.resume(throwing: SpeechFrameworkError.frameworkUnavailable)
                    return
                }

                buffer.withUnsafeBufferPointer { bufferPtr in
                    chunkBuffer.floatChannelData?[0].update(from: bufferPtr.baseAddress! + offset, count: frameCount)
                }
                chunkBuffer.frameLength = AVAudioFrameCount(frameCount)

                request.append(chunkBuffer)
                offset = end
            }
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

                let tokens = (result.transcriptions.first?.segments ?? []).map { segment in
                    TranscribedToken(
                        text: segment.substring,
                        onsetTime: segment.timestamp,
                        duration: segment.duration,
                        confidence: nil
                    )
                }

                continuation.resume(returning: tokens)
            }
        }
    }

    // MARK: - iOS 26 SpeechAnalyzer path

    /// iOS 26+ path: Apple's `SpeechAnalyzer` + `SpeechTranscriber`. Emits per-word tokens whose
    /// onset/duration come from the time-indexed result attribute (`audioTimeRange`, a `CMTimeRange`),
    /// with optional per-token confidence (`transcriptionConfidence`, a `Double`) when
    /// `configuration.includeConfidence`. The on-device model asset is installed on demand; if it can't
    /// be made available the method throws so the caller falls back to SFSpeechRecognizer.
    ///
    /// `configuration.waitForFinalResult` is honored as final-only collection (`reportingOptions` omits
    /// `.volatileResults`) — a complete pre-recorded buffer has no meaningful partial hypotheses.
    @available(iOS 26, macOS 26, *)
    private static func transcribeWithSpeechAnalyzer(
        buffer: [Float],
        sampleRate: Double,
        locale: Locale,
        configuration: Configuration
    ) async throws -> [TranscribedToken] {
        // Resolve a transcriber-supported locale (BCP 47 equivalence).
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFrameworkError.localeUnsupported(locale.identifier)
        }

        // Final results only; per-word timing always; confidence when requested.
        var attributeOptions: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange]
        if configuration.includeConfidence { attributeOptions.insert(.transcriptionConfidence) }
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: attributeOptions
        )

        // Install the on-device language model for this transcriber if it isn't already present.
        // A nil request means nothing needs installing; a thrown install error falls back to SF.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // The audio format the transcriber wants; convert our mono Float32 buffer into it.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechFrameworkError.frameworkUnavailable
        }
        let inputs = try makeAnalyzerInputs(buffer: buffer, sampleRate: sampleRate, targetFormat: analyzerFormat)

        // Stream the audio through the analyzer; collect word tokens from the transcriber's results.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let includeConfidence = configuration.includeConfidence
        let collector = Task { () throws -> [TranscribedToken] in
            var tokens: [TranscribedToken] = []
            for try await result in transcriber.results {
                let attributed = result.text
                for run in attributed.runs {
                    guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                    let word = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    let confidence: Double? = includeConfidence
                        ? run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                        : nil
                    tokens.append(TranscribedToken(
                        text: word,
                        onsetTime: timeRange.start.seconds,
                        duration: timeRange.duration.seconds,
                        confidence: confidence
                    ))
                }
            }
            return tokens
        }

        try await analyzer.start(inputSequence: stream)
        for input in inputs { continuation.yield(input) }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    /// Convert the mono Float32 `[Float]` buffer at `sampleRate` into the transcriber's required format,
    /// wrapped as `AnalyzerInput`(s). No conversion when the formats already match.
    /// Seconds per AnalyzerInput chunk. WHY CHUNKING EXISTS (2026-08-08, the "6 Human"
    /// isolation spike's real finding): SpeechAnalyzer fed ONE giant AnalyzerInput only
    /// emits results for roughly the LAST ~140–155 seconds of it — a 4:39 song lost its
    /// entire first 2:18 of sung words (first token 2:18.12), which rendered as the
    /// Songcatcher chart's missing-verse hole. Measured head-cut probes: 138s/160s inputs
    /// lose nothing; 200s loses ~60s; 278.8s loses ~138s. Chunked 10s inputs through one
    /// analyzer session transcribe the same file end to end (first token 0:13.08, 185 vs
    /// 87 tokens, the whole verse recovered). 10s is the spike-validated value.
    private static let analyzerChunkSeconds: Double = 10

    @available(iOS 26, macOS 26, *)
    private static func makeAnalyzerInputs(
        buffer: [Float],
        sampleRate: Double,
        targetFormat: AVAudioFormat
    ) throws -> [AnalyzerInput] {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw SpeechFrameworkError.frameworkUnavailable
        }
        // One converter reused across chunks (stream-style: .noDataNow between chunks, so
        // its internal state carries over and resampling stays continuous at chunk seams).
        let needsConversion = sourceFormat != targetFormat
        let converter: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw SpeechFrameworkError.frameworkUnavailable
            }
            converter = c
        } else {
            converter = nil
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate

        let chunkFrames = max(1, Int(analyzerChunkSeconds * sampleRate))
        var inputs: [AnalyzerInput] = []
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + chunkFrames, buffer.count)
            let count = end - offset
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw SpeechFrameworkError.frameworkUnavailable
            }
            sourceBuffer.frameLength = AVAudioFrameCount(count)
            buffer.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress, let dst = sourceBuffer.floatChannelData?[0] {
                    dst.update(from: base + offset, count: count)
                }
            }

            if let converter {
                let capacity = AVAudioFrameCount(Double(count) * ratio) + 4096
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(1, capacity)) else {
                    throw SpeechFrameworkError.frameworkUnavailable
                }
                var providedInput = false
                var conversionError: NSError?
                converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                    if providedInput {
                        // .noDataNow, NOT .endOfStream: the converter is reused for the next
                        // chunk, so the stream must stay open across calls.
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    providedInput = true
                    inputStatus.pointee = .haveData
                    return sourceBuffer
                }
                if let conversionError {
                    throw SpeechFrameworkError.recognitionFailed(conversionError.localizedDescription)
                }
                inputs.append(AnalyzerInput(buffer: outBuffer))
            } else {
                inputs.append(AnalyzerInput(buffer: sourceBuffer))
            }
            offset = end
        }
        return inputs
    }

    /// Transcription tuning. The Whisper field selects the engine; the SpeechAnalyzer fields
    /// apply to the iOS 26+ Apple path only (iOS 17 SFSpeechRecognizer ignores them).
    public struct Configuration: Equatable, Hashable, Sendable {
        /// Defer final results until the buffer ends, rather than returning partial hypotheses. Default: true.
        public let waitForFinalResult: Bool

        /// Include confidence scores for each token. Default: true.
        /// Only applicable to iOS 26+ SpeechAnalyzer; iOS 17 SFSpeechRecognizer always returns nil.
        public let includeConfidence: Bool

        /// Folder holding a locally-managed WhisperKit CoreML model (the validated variant is
        /// `openai_whisper-small`). When non-nil and loadable, English transcription runs through
        /// `WhisperLyricsEngine` with the pinned decode config (Sanctuary BACKLOG "Lyric
        /// transcription", GO 2026-08-07); when nil, unloadable, or on any decode failure, the
        /// Apple Speech path runs unchanged. Default: nil (Apple path only).
        ///
        /// The folder must contain the model's `.mlmodelc` bundles + configs AND the tokenizer
        /// files (`tokenizer.json` + `tokenizer_config.json`, either at the folder top level or
        /// in Hub layout `models/openai/whisper-small/` inside the folder) for a fully-offline
        /// load — without a local tokenizer WhisperKit attempts a network fetch, and an offline
        /// failure falls back to Apple. Model download/placement/eviction is the app's job.
        public let whisperModelFolder: URL?

        public init(
            waitForFinalResult: Bool = true,
            includeConfidence: Bool = true,
            whisperModelFolder: URL? = nil
        ) {
            self.waitForFinalResult = waitForFinalResult
            self.includeConfidence = includeConfidence
            self.whisperModelFolder = whisperModelFolder
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
