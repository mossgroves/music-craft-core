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
    /// - `temperatureFallbackCount 0` — THE FALLBACK LADDER IS OFF (2026-08-12). WhisperKit's
    ///   default re-decodes a window at up to six rising temperatures when the greedy pass fails
    ///   its logprob/compression gates. That policy exists for SPEECH; on music it is a
    ///   pathology: sparse, quiet or instrumental windows fail the gates on nearly every window,
    ///   each retry costs a full decode, and the high-temperature decodes produce the junk the
    ///   artifact filter then has to strip. Measured on a 2:00 sparse-vocal phone capture: the
    ///   ladder ground 372 s on an iPhone 17 Pro Max and had not finished after 60 MINUTES on an
    ///   M2 Max, where the greedy-only decode of the same file completes in seconds. Greedy-only
    ///   is also the configuration the original mlx A/B validated (10.0% WER, deterministic,
    ///   2026-08-07) — the fallback ladder was never part of the measured quality claim.
    /// Everything else stays at WhisperKit defaults (the validated configuration).
    ///
    /// `language`: a Whisper language code ("en", "es", …) forced into the prefill, or nil to
    /// let Whisper DETECT the sung language (`detectLanguage` + prefill). The shipping default
    /// stays "en" (`LyricsExtractor.Configuration.transcriptionLanguage`), and any caller-forced
    /// code now routes here regardless of locale (routing rule + measurement:
    /// `LyricsExtractor.whisperDecodeLanguage`). DETECTION IS MEASURED BROKEN on sung audio and
    /// the extractor never routes nil here (2026-08-13 Te Amo decode: detect 22/54 words vs
    /// forced-es 49/54 vs forced-en 39/54 — wrong language per slice, transliterated mojibake,
    /// a 21-glyph junk run). The nil branch stays so a future measured decision can reopen it
    /// without an API change.
    static func pinnedDecodingOptions(language: String? = "en") -> DecodingOptions {
        var options = DecodingOptions()
        if let language {
            options.language = language
        } else {
            options.detectLanguage = true
        }
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.suppressTokens = nonSpeechSuppressTokens
        options.firstTokenLogProbThreshold = -100
        options.wordTimestamps = true
        options.temperatureFallbackCount = 0
        // Decode-length ceiling per window: the densest legitimately sung 30 s window in the
        // corpus decodes to ~80 tokens (timestamps and punctuation included); 160 is a 2x
        // margin. Junk repetition never emits end-of-text and otherwise runs to the model's
        // 224 ceiling on EVERY pathological window - this cap halves what a junk window can
        // cost while sitting far above anything real singing produces (2026-08-12).
        options.sampleLength = 160
        return options
    }

    // MARK: - Artifact filter thresholds (measured, six-song device scoring 2026-08-07)

    /// Tokens below this word probability are ghosts: hallucinated words over instrumental
    /// regions measured at probability 0.03-0.19. The floor sits at 0.15 so legit quiet words
    /// (which score higher) stay. Do not raise without re-scoring the six songs.
    static let ghostConfidenceFloor: Double = 0.15

    /// THE TAKE'S FIRST WORD IS EXEMPT FROM THE FLOOR, and this is a measurement rather than a
    /// kindness (2026-08-10, Chris: *"Forever analysis also lost the opening, first word of the
    /// song"*).
    ///
    /// Whisper scores the first word of a take far lower than any other word, for reasons that
    /// have nothing to do with whether it is real: after the prefill there is no left context to
    /// condition on, and the opening syllable is usually caught mid-attack over a music bed.
    /// Measured across the six scored songs, the take-opening word scores 0.06 / 0.09 / 0.18 /
    /// 0.25 / 0.40 / 0.48 — median 0.215, against a corpus median of 0.98 for every other word.
    /// **Two of six real opening words therefore fell under a floor drawn against hallucinations.**
    /// On "1 Forever" the app printed "I have looked, forever I have found again" for a song that
    /// begins "Forever I have looked"; on "CHRIS TRAVELERS" the opening "Oh" (p=0.06) went the
    /// same way.
    ///
    /// The floor itself is untouched and still does its work — this exempts exactly ONE token,
    /// the first surviving word of the whole take, and nothing else. The asymmetry is justified
    /// because the two populations differ in a way the probability alone cannot express: a ghost
    /// is a word invented over a region with no voice in it, while the take's opening word sits
    /// at the very start of the singing. A hallucinated opener is possible; it costs one wrong
    /// word at the top of a chart the songwriter is reading anyway, against losing the real first
    /// word of every third song.
    ///
    /// Deliberately NOT extended to every segment's first token: segment-initial words score a
    /// median 0.755 with only 6% under the floor, so they do not need it, and exempting ~158
    /// tokens per song rather than one would hand the ghosts a door.
    static let exemptsTakeOpeningWordFromFloor = true

    /// A LONE final token below this confidence, ending inside the last decode window of the
    /// audio, is the measured "you"-tail artifact (Whisper hallucinating a sign-off over the
    /// fade-out; observed repeatedly across the six scored songs). 0.30 per the BACKLOG's
    /// measured cleanup range ("the confidence floor (~0.2-0.3) kills them").
    static let trailingArtifactConfidenceCeiling: Double = 0.30

    /// "End-of-audio" for the trailing-artifact rule: one Whisper decode window (30 s).
    /// The tail artifact was only ever observed in the final window over a no-vocal fade.
    static let trailingArtifactWindowSeconds: TimeInterval = 30

    /// THE RUN GUARD (0.1.17, Chris's word 2026-09-02): a run of this many or more consecutive
    /// tokens that fold to the same word is the decoder's repetition collapse, and the whole run
    /// is dropped. Measured (Sanctuary `docs/audits/repetition-levers-2026-09-01.md`): applied
    /// to the shipping output alone it took the seventeen-take mean from 80.3% to 43.1% WER,
    /// level with Apple's decoder, and the six collapsed takes from 135.5% to 29.9%. Five is the
    /// bar for the same reason it is the brake's: nothing he sings repeats a word five times
    /// running except a vocalise, and the sheet never writes those out.
    ///
    /// CONVICT BY RUN, NEVER BY SHARED TIMESTAMP. The audit's pile signature (dozens of tokens on
    /// one onset) looked like the cleaner rule and is the wrong one: the real verse that survives
    /// BEHIND a loop on 6 Human carries the loop's timestamps too, and a pile rule takes it with
    /// the junk (40.0% against 27.2% by run on that take). Runs are counted across segment
    /// boundaries, because the brake caps a chant at five per segment and the model restarts it
    /// in the next.
    static let repetitionRunFloor = 5

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
        modelFolder: URL,
        language: String? = "en"
    ) async throws -> [TranscribedToken] {
        guard !buffer.isEmpty, sampleRate > 0 else { return [] }

        let pipe = try await PipelineStore.shared.pipeline(for: modelFolder)
        let audio = try resampleTo16k(buffer, sampleRate: sampleRate)

        // ── ONE SLICE, ONE DECODE (2026-08-12): the take is fed to WhisperKit in fixed
        // window-sized slices, each its own `transcribe` call, timestamps offset back to
        // file-absolute. WHY: WhisperKit's internal seek loop advances only to the END OF THE
        // LAST SEGMENT it decoded, so a low-content window that emits a short junk segment
        // advances the seek by a second or two instead of thirty — and a 2:00 sparse-vocal
        // capture was measured decoding EIGHTY-odd crawling windows instead of four (372 s on
        // an iPhone 17 Pro Max; over an hour on an M2 Max, sampled deep in the decode loop).
        // Slicing makes the decode count `ceil(duration / 30)` BY CONSTRUCTION — a hard bound
        // no audio content can defeat. Quality is untouched: the pinned config never conditions
        // one window on another (no prompt tokens, no prompt cache), so windows were already
        // independent; the only change is that window boundaries sit on a fixed grid instead
        // of following segment ends, which costs at most a word straddling a slice boundary.
        let sliceFrames = 30 * WhisperKit.sampleRate   // one Whisper window: 480_000 frames at 16 kHz
        let audioDuration = Double(buffer.count) / sampleRate
        var collected: [[TranscribedToken]] = []
        var sliceStart = 0
        while sliceStart < audio.count {
            let sliceEnd = min(sliceStart + sliceFrames, audio.count)
            let offsetSeconds = Double(sliceStart) / Double(WhisperKit.sampleRate)
            // THE SLICE'S TOKEN BUDGET is the second half of the crawl containment (the slicing
            // above is the first). WhisperKit's internal loop can still crawl WITHIN a slice
            // (short junk segments advance the seek by seconds); once a slice has spent tokens
            // enough for `sliceWindowBudget` full windows, the early-stop callback ends every
            // further window after one token — and a window with no segments advances the seek
            // by the FULL window, so the loop reaches the slice's end in a handful of cheap
            // steps instead of dozens of full decodes. Legitimate singing never spends the
            // budget (a dense 30 s of lyrics is well under one window's 224 tokens); only
            // pathological repetition does, and its output is the junk the artifact filter
            // strips anyway. No quality threshold is introduced: the pinned decode config,
            // including the measured `firstTokenLogProbThreshold -100`, is untouched.
            // THE CRAWL IS CANCELLED, NOT OUTLASTED (2026-08-12). The budget below bounds what
            // a window may COST; the ledger's window cap bounds how many windows the slice may
            // OPEN, and its breach cancels the decode task — the only mechanism that reaches
            // WhisperKit's seek loop (see `maxWindowsPerSlice` for the measured pathology: 345
            // empty-text windows in 45 s of one near-silent slice, seek advancing <0.09 s per
            // window, token budget spent to no effect). A wall-clock watchdog backs the window
            // heuristic. A cancelled slice contributes nothing and the loop continues, so real
            // singing in a take's OTHER slices survives a crawling one.
            let ledger = SliceDecodeLedger(tokenBudget: sliceWindowBudget * 160,
                                           windowCap: maxWindowsPerSlice)
            let sliceAudio = Array(audio[sliceStart..<sliceEnd])
            let options = pinnedDecodingOptions(language: language)
            let decodeTask = Task {
                try await pipe.transcribe(audioArray: sliceAudio,
                                          decodeOptions: options,
                                          callback: { progress in
                                              ledger.note(tokenCount: progress.tokens.count)
                                          })
            }
            ledger.onWindowCapBreached = { decodeTask.cancel() }
            let watchdog = Task {
                try await Task.sleep(nanoseconds: UInt64(sliceDecodeWallCap * 1_000_000_000))
                decodeTask.cancel()
            }
            defer { watchdog.cancel() }
            do {
                let results = try await decodeTask.value
                let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
                for segment in segments {
                    let mapped = tokens(fromWords: segment.words ?? [], offsetBy: offsetSeconds)
                    if !mapped.isEmpty { collected.append(mapped) }
                }
            } catch is CancellationError {
                // The slice was crawling; its decode was producing empty segments. It stands
                // as wordless and the take moves on — this catch IS the bound.
            }
            sliceStart = sliceEnd
        }

        let filtered = filterArtifacts(segments: collected, audioDuration: audioDuration)
        // The coverage gate LAST: it judges the surviving transcript as a whole.
        return passesCoverageGate(filtered, audioDuration: audioDuration) ? filtered : []
    }

    // MARK: - Token mapping (pure)

    /// Map WhisperKit per-word timings to MCC's `TranscribedToken`.
    /// `WordTiming.word` carries Whisper's leading-space token convention (" word"), so text is
    /// whitespace-trimmed; tokens that trim to empty are dropped. `start`/`end` are absolute
    /// WITHIN THE CALL's audio (WhisperKit adds its window seek offset before emitting —
    /// SegmentSeeker, verified v1.1.0); `offsetBy` restores file-absolute time for the sliced
    /// decode (the slice's start in the whole take).
    static func tokens(fromWords words: [WordTiming], offsetBy offset: TimeInterval = 0) -> [TranscribedToken] {
        words.compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscribedToken(
                text: text,
                onsetTime: TimeInterval(word.start) + offset,
                duration: TimeInterval(max(0, word.end - word.start)),
                confidence: Double(word.probability)
            )
        }
    }

    // MARK: - Artifact filter (pure)

    /// Strip the four measured Whisper-on-music artifacts (six-song on-device scoring,
    /// 2026-08-07 — see BACKLOG "Lyric transcription", on-device validation paragraph — and the
    /// seventeen-take repetition audit, 2026-09-01):
    ///
    /// 1. **"Music" caption segments** — a segment whose every token is the word "Music"
    ///    (any case/bracketing) is Whisper captioning an instrumental intro/fade, not a lyric.
    ///    Dropped whole. A segment where "music" appears among real words is a lyric and stays.
    /// 2. **Ghost words** — tokens with word probability below `ghostConfidenceFloor` (0.15);
    ///    hallucinations over no-vocal regions measured at 0.03-0.19. Tokens with nil
    ///    confidence are kept (nothing to judge them by; only the Whisper path sets confidence).
    /// 3. **Repetition runs** — `repetitionRunFloor` (5) or more consecutive tokens folding to
    ///    one word, counted across segment boundaries, are the decoder's collapse and are
    ///    dropped whole. Confidence cannot catch this one: the loop's tokens carry 0.35 to 0.99.
    /// 4. **The "you" tail** — a lone low-confidence final token ending inside the last decode
    ///    window of the audio (Whisper's fade-out sign-off hallucination).
    ///
    /// Pure function over already-mapped tokens grouped by Whisper segment; segment grouping
    /// is required because artifacts (1) and (4) are segment-shaped, not token-shaped.
    /// Returns the surviving tokens flattened in segment order.
    static func filterArtifacts(
        segments: [[TranscribedToken]],
        audioDuration: TimeInterval
    ) -> [TranscribedToken] {
        // (1) "Music" caption segments — drop before the confidence floor: caption tokens can
        // carry high probability (the model is confident it is captioning music).
        var kept = segments.filter { !isMusicCaptionSegment($0) }

        // (2) Ghost-word floor, per token — EXCEPT the take's own first word, which Whisper
        // systematically under-scores for reasons unrelated to whether it was sung (see
        // `exemptsTakeOpeningWordFromFloor` for the measurement). The exemption is spent on
        // exactly one token in the whole take: the first token of the first segment that
        // survives the caption filter.
        var openingIsExempt = exemptsTakeOpeningWordFromFloor
        kept = kept
            .map { segment -> [TranscribedToken] in
                var isFirstOfTake = openingIsExempt
                openingIsExempt = false   // spent on the first segment we look at, kept or not
                return segment.filter { token in
                    defer { isFirstOfTake = false }
                    if isFirstOfTake { return true }
                    return (token.confidence ?? 1.0) >= ghostConfidenceFloor
                }
            }
            .filter { !$0.isEmpty }

        // (3) Repetition runs, counted over the flattened stream so a chant the brake capped at
        // five per segment and the model restarted in the next is one run, not several short
        // ones. A token that folds to nothing (pure punctuation) breaks a run.
        kept = droppingRepetitionRuns(kept)

        // (4) Trailing lone low-confidence token at end-of-audio.
        if let lastSegment = kept.last,
           lastSegment.count == 1,
           let token = lastSegment.first,
           let confidence = token.confidence,
           confidence < trailingArtifactConfidenceCeiling,
           token.offsetTime > audioDuration - trailingArtifactWindowSeconds {
            kept.removeLast()
        }

        // The recognizer's own segment boundaries, preserved (0.1.11). Marked HERE, after the
        // filters, so a dropped caption or ghost cannot leave the flag on a word that is no
        // longer the segment's first — the flag must describe the stream that is returned.
        return kept.flatMap { segment -> [TranscribedToken] in
            segment.enumerated().map { index, token in
                TranscribedToken(text: token.text, onsetTime: token.onsetTime,
                                 duration: token.duration, confidence: token.confidence,
                                 startsSegment: index == 0)
            }
        }
    }

    /// Rule (3) of `filterArtifacts`: drop every run of `repetitionRunFloor` or more consecutive
    /// tokens (across segments, in stream order) that fold to one word, then drop any segment
    /// emptied by it. Pure; segment membership of the survivors is unchanged.
    ///
    /// REPEATED TO A FIXED POINT, and this is a measurement rather than a nicety (2026-09-02, the
    /// first harness run on 0.1.17): with the brake on, Highest Heaven's outro came back as
    /// "yeah, oh oh oh oh oh oh, yeah, oh oh oh oh oh oh, yeah, …". One pass removes the "oh"
    /// chants and leaves the eleven "yeah"s that stood between them touching, a wall of one word
    /// again. Each pass removes at least `repetitionRunFloor` tokens, so it terminates.
    static func droppingRepetitionRuns(_ segments: [[TranscribedToken]]) -> [[TranscribedToken]] {
        var current = segments
        while true {
            let next = droppingRepetitionRunsOnce(current)
            if next.map(\.count) == current.map(\.count) { return next }
            current = next
        }
    }

    /// One pass of rule (3). See `droppingRepetitionRuns` for why it is iterated.
    static func droppingRepetitionRunsOnce(_ segments: [[TranscribedToken]]) -> [[TranscribedToken]] {
        // Flatten with (segment, index) addresses so a run can be found across boundaries and
        // removed from the segments it spans.
        var addresses: [(segment: Int, index: Int, word: String)] = []
        for (s, segment) in segments.enumerated() {
            for (i, token) in segment.enumerated() {
                addresses.append((s, i, RepetitionBrake.fold(token.text)))
            }
        }
        var convicted = Set<Int>()   // positions in `addresses`
        var start = 0
        while start < addresses.count {
            var end = start
            let word = addresses[start].word
            if !word.isEmpty {
                while end + 1 < addresses.count, addresses[end + 1].word == word { end += 1 }
            }
            if end - start + 1 >= repetitionRunFloor {
                for position in start...end { convicted.insert(position) }
            }
            start = end + 1
        }
        guard !convicted.isEmpty else { return segments }
        var droppedAt: [Int: Set<Int>] = [:]
        for position in convicted {
            droppedAt[addresses[position].segment, default: []].insert(addresses[position].index)
        }
        return segments.enumerated().compactMap { s, segment -> [TranscribedToken]? in
            guard let dropped = droppedAt[s] else { return segment }
            let survivors = segment.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
            return survivors.isEmpty ? nil : survivors
        }
    }

    /// How many full windows' worth of tokens one 30 s slice may spend before its remaining
    /// windows are early-stopped (see the budget comment in `transcribe`). A healthy slice is
    /// ONE window; two covers WhisperKit legitimately re-windowing once after a segment that
    /// ends early. Structural, not tuned: 2 × 160 tokens is ~4× the densest sung 30 s
    /// window in the corpus (~80 tokens).
    static let sliceWindowBudget = 2

    /// HOW MANY WINDOWS one slice's internal seek loop may open before the slice is judged to
    /// be crawling and its decode is CANCELLED (2026-08-12, the second half of the crawl fix —
    /// the token budget alone turned out not to be a bound).
    ///
    /// THE MEASURED HOLE the cap closes: on the 2:00 sparse capture ("recorded at 9:09 PM",
    /// the take the 0.1.12 slicing was built for), a near-silent 30 s slice decodes to an
    /// EMPTY segment whose closing timestamp sits fractions of a second in — and WhisperKit's
    /// seek advances only to that timestamp. Traced on a Mac (release, pinned config):
    /// **345 windows opened in the first 45 s of ONE slice**, 4 callbacks each, empty text,
    /// mean seek advance under 0.09 s per window. The token budget spent itself at ~window 80
    /// and changed nothing, because a window's 3-4 prefill-token callbacks fire before the
    /// early-stop can bite, and returning false from the callback ends only the CURRENT
    /// window's token loop — the seek loop (upstream `TranscribeTask.swift:135-165`, v1.1.0)
    /// is unreachable from the callback. Cancellation is the one lever that reaches it:
    /// WhisperKit checks `Task.checkCancellation()` in the seek loop, the encoder, and the
    /// decoder, so cancelling the slice's task stops the crawl within one window.
    ///
    /// The value is structural, not tuned: a healthy slice is 1-2 windows (the corpus decodes
    /// 0.7-10.4 s per TAKE), a legitimately choppy sung slice a handful, and a crawling slice
    /// hundreds. 8 is ~4× the legitimate re-window case and two orders of magnitude under the
    /// pathology. A cancelled slice contributes NO tokens — on crawling audio the decode was
    /// producing empty segments anyway, so nothing real is lost — and the take's other slices
    /// decode normally, preserving any singing they hold.
    static let maxWindowsPerSlice = 8

    /// Wall-clock belt to the window cap's suspenders: a slice whose decode outlives this many
    /// seconds is cancelled regardless of window count, so no pathology the window heuristic
    /// misses can grind unbounded. A healthy slice decodes in ~1-4 s (Mac release and
    /// iPhone 17 Pro Max both); 15 s is ~4× that worst case.
    static let sliceDecodeWallCap: TimeInterval = 15

    /// The per-slice decode ledger: spends the token budget (early-stopping windows once it is
    /// gone, exactly as the old `TokenBudgetCounter` did) AND counts window transitions,
    /// firing `onWindowCapBreached` once when the slice betrays the crawl. Window transitions
    /// are detected by the progress token count dropping — WhisperKit accumulates tokens
    /// within a window and resets for the next one.
    ///
    /// Thread-safe (`NSLock`) because WhisperKit invokes the progress callback from its decode
    /// context, not the caller's; the breach handler is installed AFTER the decode task is
    /// created, so `onWindowCapBreached`'s setter fires it immediately when the cap was
    /// breached before installation (a 1.5 s-deep crawl by then — unlikely but free to handle).
    /// Internal (not private) so the pure window/budget logic is testable via @testable.
    final class SliceDecodeLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingTokens: Int
        private let windowCap: Int
        private var windowCount = 0
        private var lastTokenCount = Int.max
        private var breached = false
        private var breachHandler: (() -> Void)?

        init(tokenBudget: Int, windowCap: Int) {
            remainingTokens = tokenBudget
            self.windowCap = windowCap
        }

        var onWindowCapBreached: (() -> Void)? {
            get { lock.lock(); defer { lock.unlock() }; return breachHandler }
            set {
                let fireNow: Bool
                lock.lock()
                breachHandler = newValue
                fireNow = breached && newValue != nil
                lock.unlock()
                if fireNow { newValue?() }
            }
        }

        /// One progress callback: notes a window transition when the token count resets,
        /// fires the breach handler once at the cap, and returns the token-budget verdict
        /// (true = keep decoding this window, false = early-stop it).
        ///
        /// `<=`, not `<`: within one window the count strictly RISES, so an equal count can
        /// only be the next window resetting to the same value — which is exactly what the
        /// post-budget regime produces (every early-stopped window emits one token: 1, 1, 1…).
        /// A strict `<` would leave those windows invisible to the cap.
        func note(tokenCount: Int) -> Bool {
            var fire: (() -> Void)?
            lock.lock()
            if tokenCount <= lastTokenCount {
                windowCount += 1
                if windowCount > windowCap && !breached {
                    breached = true
                    fire = breachHandler
                }
            }
            lastTokenCount = tokenCount
            remainingTokens -= 1
            let keepDecoding = remainingTokens > 0
            lock.unlock()
            fire?()
            return keepDecoding
        }
    }

    // MARK: - The coverage gate (pure)

    /// A TRANSCRIPT MUST EARN ITS CLAIM TO BE WORDS (2026-08-12). A completely instrumental
    /// 2:30 capture came back titled "it's a great" from ~10 hallucinated words that each
    /// individually cleared the per-token ghost floor — no per-token rule can catch a take
    /// whose words are sparse-and-weak AS A WHOLE. The gate judges the whole: on a take long
    /// enough to judge (`coverageGateMinimumDuration`), a surviving transcript that is BOTH
    /// thinner than `coverageGateMinWordsPerMinute` AND weaker than
    /// `coverageGateMinMeanConfidence` is Whisper decorating an instrumental, and the honest
    /// transcript is NO transcript — the wordless take flow (a sketch, a hum) already says the
    /// right things. Both clauses must fail together: sparse-but-CONFIDENT words (a genuine
    /// line in a long instrumental) and dense-but-mumbled singing both pass.
    ///
    /// Thresholds placed from the corpus populations, 2026-08-12 (capped decode, 15-take
    /// corpus + wordless stem specimens): real sung takes measure (wpm, mean conf) of
    /// (48.4, 0.76), (52.0, 0.72), (25.7, 0.58), (21.4, 0.82); hallucination over instrumental
    /// audio measures (22.1, 0.43) on the clean stem specimen and ~4 wpm on the device's
    /// instrumental capture. Every real take passes at least one clause with >=16% margin;
    /// junk fails both. The gate's cost is deliberately LOW either way: the caller
    /// (LyricsExtractor) treats an empty Whisper result as "consult the Apple path", so a
    /// gated transcript is a second opinion, never a loss - which is what makes modest margins
    /// acceptable for sparse garbled-but-real singing (measured (17.0, 0.28), gated, and
    /// correctly recovered by the Apple path's own reading).
    static let coverageGateMinimumDuration: TimeInterval = 30
    static let coverageGateMinWordsPerMinute: Double = 25
    static let coverageGateMinMeanConfidence: Double = 0.50

    /// True when the surviving transcript stands as words; false → the caller returns [] and
    /// the take reads honestly as wordless. Empty input passes vacuously (nothing to judge).
    static func passesCoverageGate(
        _ tokens: [TranscribedToken],
        audioDuration: TimeInterval
    ) -> Bool {
        guard audioDuration >= coverageGateMinimumDuration, !tokens.isEmpty else { return true }
        let wordsPerMinute = Double(tokens.count) / (audioDuration / 60)
        let confidences = tokens.compactMap(\.confidence)
        // No confidences at all → nothing to weigh the words with; the rate clause alone
        // cannot convict (the Apple path never reaches here, but the contract stays honest).
        guard !confidences.isEmpty else { return true }
        let meanConfidence = confidences.reduce(0, +) / Double(confidences.count)
        return wordsPerMinute >= coverageGateMinWordsPerMinute
            || meanConfidence >= coverageGateMinMeanConfidence
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
            // THE REPETITION BRAKE rides every decode this pipeline makes (0.1.17). Installed
            // here rather than through `WhisperKitConfig.logitsFilters` because its fold table
            // needs the tokenizer, which exists only after the pipeline has loaded. WhisperKit
            // prepends custom filters to its own (suppress-tokens, timestamp rules), so the
            // pinned config is untouched. See `RepetitionBrake` for the measurement.
            if let tokenizer = pipe.tokenizer {
                pipe.textDecoder.logitsFilters = [RepetitionBrake(tokenizer: tokenizer)]
            }
            cachedPath = folder.path
            cachedPipe = pipe
            return pipe
        }
    }
}
