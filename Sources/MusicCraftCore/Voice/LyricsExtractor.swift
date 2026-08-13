import Foundation
import Speech
import AVFAudio
import CoreMedia

/// On-device lyric transcription wrapper. Produces timestamped word-level tokens for alignment
/// with chord and melody timelines.
///
/// Engine order (Sanctuary BACKLOG "Lyric transcription", GO 2026-08-07; language routing
/// widened per the language-honesty spec, 2026-08-13):
/// 1. **WhisperLyricsEngine** (WhisperKit CoreML, whisper-small) — when the consumer provides
///    `Configuration.whisperModelFolder` AND the routing rule (`whisperDecodeLanguage`) names a
///    decode language: any non-nil `transcriptionLanguage` code, with the original English-locale
///    gate retained for the default "en". The quality path for SUNG material.
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
    /// WARM THE WHISPER ENGINE AHEAD OF TIME. Loads the Core ML pipeline for
    /// `configuration.whisperModelFolder` into the process cache so the next `transcribe` call
    /// pays only for decoding. A no-op when no folder is configured (the Apple paths have no
    /// consumer-loadable model), and idempotent — the pipeline cache serves every later call.
    ///
    /// THE COST IT MOVES (Sanctuary device report, Chris 2026-08-09: a six-second recording took
    /// over twenty seconds to analyze). Whisper's model load is FIXED — it does not shrink with
    /// the audio — so on a short take it is not part of the analysis time, it IS the analysis
    /// time. Measured on this Mac for `openai_whisper-small`: 28.1 s for the first-ever load after
    /// a fetch (Core ML specializing for the neural engine), 0.57 s for every later load in a
    /// fresh process, 0.21 s to decode the 6-second clip itself. Device figure for that first load
    /// is 22 s (iPhone 17 Pro Max, Sanctuary BACKLOG "Lyric transcription", 2026-08-07).
    ///
    /// FAIL-SOFT, LIKE THE READ PATH: any load failure is swallowed. A folder that cannot load is
    /// not an error to warm — it simply means the next `transcribe` takes the Apple path, and
    /// warming must never be a reason a caller shows an error it would not otherwise show.
    ///
    /// WHEN to warm is the APP's policy, not MCC's: MCC has no idea when a songwriter is about to
    /// sing. Warming holds the loaded models resident (measured peak footprint 139-160 MB during
    /// transcription), so a caller that warms at launch and never records has paid memory for
    /// nothing. Songcatcher warms when the download finishes and when a capture surface opens.
    public static func prepare(configuration: Configuration) async {
        guard let modelFolder = configuration.whisperModelFolder else { return }
        try? await WhisperLyricsEngine.preload(modelFolder: modelFolder)
    }

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

        // Whisper-first when the routing rule names a decode language — the rule itself lives
        // in `whisperDecodeLanguage` below (pure, unit-tested) with the 2026-08-13 Te Amo
        // measurement that widened it beyond the original English-only gate.
        // ANY Whisper failure (unloadable folder, missing tokenizer, decode error — including a
        // language code the loaded model's tokenizer does not carry) falls through to the Apple
        // path below, which ships unchanged as the fallback floor.
        if let modelFolder = configuration?.whisperModelFolder,
           let decodeLanguage = whisperDecodeLanguage(
               localeIdentifier: localeIdentifier, configuration: configuration
           ) {
            do {
                let whisperTokens = try await WhisperLyricsEngine.transcribe(
                    buffer: buffer,
                    sampleRate: sampleRate,
                    modelFolder: modelFolder,
                    language: decodeLanguage
                )
                // AN EMPTY WHISPER RESULT CONSULTS THE APPLE PATH (2026-08-12). Empty means
                // either genuine silence or the engine's coverage gate refusing a
                // sparse-and-weak transcript as probable hallucination — and the gate is
                // deliberately allowed to be strict BECAUSE this fallback exists: sparse
                // garbled-but-real singing that Whisper cannot stand behind gets the second
                // engine's independent reading (measured recovering 34 real tokens on a take
                // Whisper gated), while true instrumentals get Apple's near-silence and the
                // honest wordless flow. Falling through costs one Apple pass, only on takes
                // that produced no usable Whisper words anyway.
                if !whisperTokens.isEmpty { return whisperTokens }
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

    /// THE WHISPER ROUTING RULE, held as a pure function so the rule is unit-testable without a
    /// model on disk. Returns the language code the Whisper path decodes as, or nil when the
    /// request takes the Apple path instead.
    ///
    /// Measured basis (language-honesty spec; 2026-08-13 decode of the Te Amo take — Spanish
    /// verses, English bridge): forced-es 49/54 words vs forced-en 39/54 vs detect 22/54.
    /// English rides along under any forced language token (the English bridge came back
    /// word-perfect under forced-es), so forcing the caller's language is safe even for
    /// mixed-language songs. The rule, top to bottom:
    ///
    /// - **A non-English `transcriptionLanguage` routes to Whisper regardless of locale.** The
    ///   field defaults to "en", so any non-English code is by construction the caller's explicit
    ///   choice; the caller (not MCC) is responsible for it being a code the model's tokenizer
    ///   carries — an unsupported code fails the decode and lands on the Apple fallback, never in
    ///   a silent wrong-language decode.
    /// - **"en" — the field's DEFAULT — keeps the original English-locale gate** (shipped
    ///   2026-08-07): a non-English REQUEST under a default configuration still goes to the Apple
    ///   path in its own locale rather than being silently decoded as English. That silent decode
    ///   is the measured confidently-dishonest failure: forced-en hallucinated "I'm going to go
    ///   to the hospital." for the Spanish opening "Te amo madre, amo tu medicina" at per-word
    ///   confidences up to 0.99. Known edge, accepted: an EXPLICIT "en" is indistinguishable from
    ///   the default, so explicit-en under a non-English locale also takes the Apple path — which
    ///   is exactly the caller this gate exists to protect.
    /// - **nil never routes to Whisper.** nil documents Whisper's own language DETECTION
    ///   (plumbed 2026-08-12, `WhisperLyricsEngine` nil branch), and detection measured
    ///   confidently dishonest on sung audio (2026-08-13: wrong language per slice, transliterated
    ///   mojibake, a 21-glyph junk run; 22/54 on Te Amo). The engine plumbing stays for a future
    ///   measured decision, but no request reaches it from here.
    static func whisperDecodeLanguage(
        localeIdentifier: String,
        configuration: Configuration?
    ) -> String? {
        guard let configuration,
              configuration.whisperModelFolder != nil,
              let requested = configuration.transcriptionLanguage else { return nil }
        if requested.lowercased() == "en" {
            // The original 2026-08-07 gate, verbatim: English decode only for English requests.
            return localeIdentifier.lowercased().hasPrefix("en") ? requested : nil
        }
        return requested
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

        /// The language the Whisper path decodes as: a Whisper code ("en", "es", …) forced into
        /// the prefill. Default "en" — the measured configuration (2026-08-07 six-song validation
        /// was English-forced). Any NON-English code routes the request to Whisper regardless of
        /// locale (the routing rule and its 2026-08-13 Te Amo measurement — forced-es 49/54 vs
        /// forced-en 39/54 vs detect 22/54, English riding along under any language token — live
        /// at `whisperDecodeLanguage`); "en" keeps the original English-locale gate. Picking WHICH
        /// code to force is the consuming app's job (the model's own `tokenizer_config.json` is
        /// the ground truth for supported codes — 99 for `openai_whisper-small`); an unsupported
        /// code fails the decode and falls back to Apple.
        ///
        /// nil documents Whisper language DETECTION and is RETIRED as a routing option (the
        /// 2026-08-13 measurement closed it: detection on sung audio picked wrong languages per
        /// slice and emitted junk-glyph runs — confidently dishonest). nil never reaches Whisper;
        /// the field stays Optional and the engine's detect plumbing stays in place so a future
        /// measured decision can reopen it without an API change. Ignored by the Apple path
        /// (which uses `locale`).
        public let transcriptionLanguage: String?

        public init(
            waitForFinalResult: Bool = true,
            includeConfidence: Bool = true,
            whisperModelFolder: URL? = nil,
            transcriptionLanguage: String? = "en"
        ) {
            self.waitForFinalResult = waitForFinalResult
            self.includeConfidence = includeConfidence
            self.whisperModelFolder = whisperModelFolder
            self.transcriptionLanguage = transcriptionLanguage
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
