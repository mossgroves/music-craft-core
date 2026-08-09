import AVFAudio
import Foundation
import WhisperKit

/// Whisper (WhisperKit CoreML) transcription engine for SUNG lyrics over a full mix.
///
/// This is the quality path behind `LyricsExtractor.transcribe`: when the consumer provides
/// `Configuration.whisperModelFolder` (a locally-managed `openai_whisper-small` WhisperKit
/// CoreML model), transcription runs here; on ANY failure the caller falls back to the Apple
/// SpeechAnalyzer / SFSpeechRecognizer path unchanged — that path remains the shipping floor.
///
/// Evidence chain (Sanctuary BACKLOG.md "Lyric transcription — WhisperKit", all 2026-08-07):
/// - whisper-small beat Apple SpeechAnalyzer on hook/melisma material across a six-song
///   head-to-head (aggregate 15.0% vs 17.9% WER; "Human" hook 8/12 vs 1/12) — the material a
///   songwriter cares most about.
/// - WhisperKit's DEFAULT decode is unshippable on music: 92.2% WER measured ("6 Human"),
///   because WhisperKit does not replicate OpenAI's decode-time non-speech suppression, so
///   music-bed windows greedy-sample `<|nocaptions|>` and are dropped as silence. The pinned
///   config below is the measured rescue (26.1% WER, hook 12/12 on the same song/scorer).
/// - On-device (iPhone 17 Pro Max): 4-5 min songs transcribe in 4.3-12.6s, thermal nominal,
///   peak footprint 139-160MB — performance is a non-issue.
///
/// Model MANAGEMENT (download, disk placement, eviction) is the consuming app's job; MCC only
/// loads whatever folder it is handed. Internal by design — the public surface is
/// `LyricsExtractor.Configuration.whisperModelFolder`.
enum WhisperLyricsEngine {
    // MARK: - Pinned decode configuration

    /// OpenAI's decode-time non-speech suppression list for the whisper-small tokenizer
    /// (mlx tokenizer `non_speech_tokens`) plus the no_speech token 50362. Copied verbatim
    /// from the WhisperBench harness (BenchModel.nonSpeechSuppressTokens, commit 73a1a36).
    /// WhisperKit does not apply this itself; without it, music-bed windows decode to
    /// `<|nocaptions|>` or [MUSIC]/notation tags (the 92.2%-WER failure, parity check 2026-08-07).
    static let nonSpeechSuppressTokens: [Int] = [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27, 28, 29, 31, 58, 59, 60, 61, 62, 63,
        90, 91, 92, 93, 359, 503, 522, 542, 873, 893, 902, 918, 922, 931, 1350,
        1853, 1982, 2460, 2627, 3246, 3253, 3268, 3536, 3846, 3961, 4183, 4667,
        6585, 6647, 7273, 9061, 9383, 10428, 10929, 11938, 12033, 12331, 12562,
        13793, 14157, 14635, 15265, 15618, 16553, 16604, 18362, 18956, 20075,
        21675, 22520, 26130, 26161, 26435, 28279, 29464, 31650, 32302, 32470,
        36865, 42863, 47425, 49870, 50254, 50362,
    ]

    /// The PINNED decode config — mandatory, never loosen without re-measuring (2026-08-07
    /// parity check + on-device validation, six songs):
    /// - `language "en"` + `usePrefillPrompt` — prefills `<|en|><|transcribe|>` so
    ///   `<|nocaptions|>` can never be greedy-sampled over a music bed.
    /// - `suppressTokens` — the OpenAI non-speech list above (+ 50362).
    /// - `firstTokenLogProbThreshold -100` — disables the first-token logprob gate that
    ///   otherwise discards whole windows on music.
    /// - `wordTimestamps` — per-word {start, end, probability}, the alignment payload.
    /// - NO initial prompt EVER (`promptTokens` stays nil): a title prompt measured a
    ///   56.7%-WER repetition catastrophe.
    /// Everything else stays at WhisperKit defaults (the validated configuration).
    static func pinnedDecodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.language = "en"
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.suppressTokens = nonSpeechSuppressTokens
        options.firstTokenLogProbThreshold = -100
        options.wordTimestamps = true
        return options
    }

    // MARK: - Artifact filter thresholds (measured, six-song device scoring 2026-08-07)

    /// Tokens below this word probability are ghosts: hallucinated words over instrumental
    /// regions measured at probability 0.03-0.19. The floor sits at 0.15 so legit quiet words
    /// (which score higher) stay. Do not raise without re-scoring the six songs.
    static let ghostConfidenceFloor: Double = 0.15

    /// A LONE final token below this confidence, ending inside the last decode window of the
    /// audio, is the measured "you"-tail artifact (Whisper hallucinating a sign-off over the
    /// fade-out; observed repeatedly across the six scored songs). 0.30 per the BACKLOG's
    /// measured cleanup range ("the confidence floor (~0.2-0.3) kills them").
    static let trailingArtifactConfidenceCeiling: Double = 0.30

    /// "End-of-audio" for the trailing-artifact rule: one Whisper decode window (30 s).
    /// The tail artifact was only ever observed in the final window over a no-vocal fade.
    static let trailingArtifactWindowSeconds: TimeInterval = 30

    // MARK: - Warming

    /// LOAD THE PIPELINE WITHOUT TRANSCRIBING ANYTHING, so the first real transcription of a
    /// process does not pay for it. Idempotent: a second call with the same folder returns the
    /// pipeline the first one cached.
    ///
    /// WHY THIS EXISTS (Sanctuary device report, Chris 2026-08-09: a SIX-SECOND recording took
    /// over twenty seconds to analyze). Model load is a FIXED cost that does not scale with the
    /// audio, so on a short take it IS the analysis time. Measured on this Mac (Apple Silicon,
    /// ANE, `openai_whisper-small`): the first-ever load after a fetch costs 28.1 s — Core ML
    /// specializing the model for the neural engine, an artifact the OS then caches — while every
    /// later load in a fresh process costs 0.57 s and the 6-second decode itself costs 0.21 s.
    /// The device number for that first load is 22 s (iPhone 17 Pro Max, WhisperBench, Sanctuary
    /// BACKLOG "Lyric transcription", 2026-08-07).
    ///
    /// MCC only offers the capability; WHEN to warm is the app's policy (Songcatcher warms when
    /// the model finishes downloading and when a capture surface opens). Throws exactly what
    /// `transcribe` would throw for the same folder, so a caller that wants to know can ask;
    /// `LyricsExtractor.prepare` swallows it, matching the fail-soft contract of the read path.
    static func preload(modelFolder: URL) async throws {
        _ = try await PipelineStore.shared.pipeline(for: modelFolder)
    }

    // MARK: - Transcription

    /// Transcribe a mono Float32 buffer with the pinned Whisper config, then strip the
    /// measured artifacts. Throws when the model folder does not hold a loadable model or
    /// decoding fails — the caller (LyricsExtractor) treats any throw as "fall back to Apple".
    ///
    /// Feed the FULL MIX, never an isolated stem: the AUSoundIsolation stem measured 23.9%
    /// WER vs 17.5% on the same song's mix (A/B eval, 2026-08-07).
    static func transcribe(
        buffer: [Float],
        sampleRate: Double,
        modelFolder: URL
    ) async throws -> [TranscribedToken] {
        guard !buffer.isEmpty, sampleRate > 0 else { return [] }

        let pipe = try await PipelineStore.shared.pipeline(for: modelFolder)
        let audio = try resampleTo16k(buffer, sampleRate: sampleRate)
        let results = try await pipe.transcribe(
            audioArray: audio,
            decodeOptions: pinnedDecodingOptions()
        )

        // Chunked decodes can return several results; segments sort by start time.
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        let grouped = segments
            .map { tokens(fromWords: $0.words ?? []) }
            .filter { !$0.isEmpty }
        let audioDuration = Double(buffer.count) / sampleRate
        return filterArtifacts(segments: grouped, audioDuration: audioDuration)
    }

    // MARK: - Token mapping (pure)

    /// Map WhisperKit per-word timings to MCC's `TranscribedToken`.
    /// `WordTiming.word` carries Whisper's leading-space token convention (" word"), so text is
    /// whitespace-trimmed; tokens that trim to empty are dropped. `start`/`end` are file-absolute
    /// (WhisperKit adds the window seek offset before emitting — SegmentSeeker, verified v1.1.0).
    static func tokens(fromWords words: [WordTiming]) -> [TranscribedToken] {
        words.compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscribedToken(
                text: text,
                onsetTime: TimeInterval(word.start),
                duration: TimeInterval(max(0, word.end - word.start)),
                confidence: Double(word.probability)
            )
        }
    }

    // MARK: - Artifact filter (pure)

    /// Strip the three measured Whisper-on-music artifacts (six-song on-device scoring,
    /// 2026-08-07 — see BACKLOG "Lyric transcription", on-device validation paragraph):
    ///
    /// 1. **"Music" caption segments** — a segment whose every token is the word "Music"
    ///    (any case/bracketing) is Whisper captioning an instrumental intro/fade, not a lyric.
    ///    Dropped whole. A segment where "music" appears among real words is a lyric and stays.
    /// 2. **Ghost words** — tokens with word probability below `ghostConfidenceFloor` (0.15);
    ///    hallucinations over no-vocal regions measured at 0.03-0.19. Tokens with nil
    ///    confidence are kept (nothing to judge them by; only the Whisper path sets confidence).
    /// 3. **The "you" tail** — a lone low-confidence final token ending inside the last decode
    ///    window of the audio (Whisper's fade-out sign-off hallucination).
    ///
    /// Pure function over already-mapped tokens grouped by Whisper segment; segment grouping
    /// is required because artifacts (1) and (3) are segment-shaped, not token-shaped.
    /// Returns the surviving tokens flattened in segment order.
    static func filterArtifacts(
        segments: [[TranscribedToken]],
        audioDuration: TimeInterval
    ) -> [TranscribedToken] {
        // (1) "Music" caption segments — drop before the confidence floor: caption tokens can
        // carry high probability (the model is confident it is captioning music).
        var kept = segments.filter { !isMusicCaptionSegment($0) }

        // (2) Ghost-word floor, per token.
        kept = kept
            .map { segment in
                segment.filter { ($0.confidence ?? 1.0) >= ghostConfidenceFloor }
            }
            .filter { !$0.isEmpty }

        // (3) Trailing lone low-confidence token at end-of-audio.
        if let lastSegment = kept.last,
           lastSegment.count == 1,
           let token = lastSegment.first,
           let confidence = token.confidence,
           confidence < trailingArtifactConfidenceCeiling,
           token.offsetTime > audioDuration - trailingArtifactWindowSeconds {
            kept.removeLast()
        }

        return kept.flatMap { $0 }
    }

    /// True when every token in the segment normalizes to "music" (case-insensitive, ignoring
    /// punctuation/brackets) — the measured instrumental-intro/fade caption artifact shape.
    /// An empty segment is not a caption segment.
    static func isMusicCaptionSegment(_ segment: [TranscribedToken]) -> Bool {
        guard !segment.isEmpty else { return false }
        return segment.allSatisfy { token in
            let letters = token.text.lowercased().filter { $0.isLetter }
            return letters == "music"
        }
    }

    // MARK: - Audio preparation

    /// Resample the mono Float32 buffer to WhisperKit's required 16 kHz. Uses WhisperKit's own
    /// public resampler (AVAudioConverter under the hood) so the input matches what the model
    /// was validated against. No-op when the buffer is already 16 kHz.
    static func resampleTo16k(_ buffer: [Float], sampleRate: Double) throws -> [Float] {
        let targetRate = Double(WhisperKit.sampleRate) // 16_000
        guard sampleRate != targetRate else { return buffer }

        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(buffer.count)
            )
        else {
            throw LyricsExtractor.SpeechFrameworkError.recognitionFailed(
                "Whisper path could not build a source audio buffer at \(sampleRate) Hz"
            )
        }
        sourceBuffer.frameLength = AVAudioFrameCount(buffer.count)
        buffer.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress, let destination = sourceBuffer.floatChannelData?[0] {
                destination.update(from: base, count: buffer.count)
            }
        }

        guard let resampled = AudioProcessor.resampleAudio(
            fromBuffer: sourceBuffer,
            toSampleRate: targetRate,
            channelCount: 1
        ) else {
            throw LyricsExtractor.SpeechFrameworkError.recognitionFailed(
                "Whisper path failed to resample \(sampleRate) Hz audio to 16 kHz"
            )
        }
        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    // MARK: - Pipeline cache

    /// One loaded WhisperKit pipeline, keyed by model-folder path. Model load costs seconds
    /// (~22 s first-ever load on iPhone 17 Pro Max including CoreML specialization) while a
    /// full-song transcription costs 4-13 s — reloading per call would dominate the run.
    /// A folder change (app swaps model tiers) replaces the cached pipeline.
    ///
    /// THE CACHE IS PROCESS-LIFETIME AND IT WORKS — measured, not assumed (2026-08-09, three
    /// consecutive `LyricsExtractor.transcribe` calls on one 6-second clip in one process, each
    /// with a freshly-constructed `Configuration`, mirroring Songcatcher building a new analyzer
    /// per capture): 1.207 s, then 0.238 s, then 0.225 s. Only the first pays the load. Nothing a
    /// consumer does at ITS layer can defeat this, because the store hangs off a module-level
    /// `static let` and is keyed by path, not held by the caller. What the cache cannot survive is
    /// process death, which is why `preload` exists.
    ///
    /// Actor reentrancy note: two simultaneous first calls can both build a pipeline; the
    /// second overwrites the first (both are valid). Accepted — capture saves are serial in
    /// practice, and correctness is unaffected.
    private actor PipelineStore {
        static let shared = PipelineStore()

        private var cachedPath: String?
        private var cachedPipe: WhisperKit?

        func pipeline(for folder: URL) async throws -> WhisperKit {
            if let cachedPipe, cachedPath == folder.path {
                return cachedPipe
            }
            // download: false — MCC never touches the network for model WEIGHTS; the folder
            // either loads or this throws and the caller falls back to Apple. (The tokenizer
            // is also resolved locally when the app places tokenizer.json in the model folder
            // — see Configuration.whisperModelFolder docs.)
            //
            // prewarm: FALSE, and the reason is a correction of what this line used to claim
            // (2026-08-09). It read `prewarm: true` with the comment "sequential per-model CoreML
            // specialization keeps peak load memory down (one model in memory at a time)". That is
            // not what the flag does. Read upstream (WhisperKit 1.1.0 `Models.swift:24`,
            // `WhisperKit.swift:360-437`): `prewarmModels()` is `loadModels(prewarmMode: true)`,
            // and in prewarm mode each model is loaded and then IMMEDIATELY DISCARDED
            // (`model = prewarmMode ? nil : loadedModel`). With `load: true` set as well, all three
            // `MLModel.load` calls simply run a second time. It stages nothing: peak memory is set
            // by the real load pass, which retains all three either way. Measured on this Mac with
            // the Core ML specialization cache already warm: 0.850 s with prewarm against 0.572 s
            // without, for byte-identical loaded models. The duplicate pass is pure latency on the
            // first transcription of every process, so it is gone.
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            cachedPath = folder.path
            cachedPipe = pipe
            return pipe
        }
    }
}
