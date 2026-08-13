import Foundation

/// Offline audio analysis pipeline producing chord progressions, key, contour, and detected notes from a PCM buffer.
///
/// AudioExtractor transcribes the buffer with a bundled **Basic Pitch** Core ML model and derives every
/// `Result` field from the note transcription: note-native chord segments (`NoteChordIdentifier`), key
/// (`ProgressionAnalyzer` over the chords, with a `MelodyKeyInference` fallback), a melodic contour, and the
/// raw detected notes.
///
/// **Key inference strategy:**
/// 1. If chord segments produce a usable progression (≥2 distinct chords), use ProgressionAnalyzer.inferKey (chord-based).
/// 2. Else if detected notes are populated, use MelodyKeyInference.infer (pitch-class-based) and take the top candidate's key.
/// 3. Else Result.key is nil.
///
/// This two-path approach leverages the strongest signal available: chord progressions when the audio contains
/// harmonic content, pitch class distributions when it contains melody only.
///
/// **Note/chord source:** the bundled Basic Pitch model is the single transcription front-end (the hand-rolled
/// YIN + FFT-chroma DSP pipeline was removed in 0.1.0). `detectedNotes` is the full polyphonic transcription
/// (key/harmony read the harmonic content from it); `contour` is a melodic-skyline reduction of the same notes;
/// `chordSegments` are note-native names over 1 s windows.
///
/// **I/O:** the model is loaded the first time `extract` runs (once, process-wide via a cached `static let`), so
/// the type is no longer a pure / no-I/O function. If the model can't load, `extract` degrades to a well-formed
/// empty `Result` rather than crashing.
///
/// **The vocal-stem side-channel (0.1.8).** A take that contains singing can have its `contour` — and ONLY its
/// `contour` — traced from an isolated vocal signal instead of from the mix, via
/// `Configuration.contourSource == .isolatedVoice` or the `isolatedVoice:` overload. Everything else in
/// `Result` still comes from the single mix pass, unchanged. See `ContourSource` for the measured evidence and
/// the gating rule.
public enum AudioExtractor {

    /// Extract chord segments, key, melodic contour, and detected notes from an audio buffer.
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples.
    ///   - sampleRate: Sample rate in Hz (typically 44100 or 48000).
    ///   - configuration: Optional tuning. Retained for API compatibility; the Basic Pitch front-end derives
    ///     its own note events, so the legacy DSP-tuning fields are vestigial under the current path. The one
    ///     field the current path DOES read is `contourSource`.
    /// - Returns: Bundled extraction result.
    public static func extract(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> Result {
        extract(buffer: buffer, sampleRate: sampleRate, configuration: configuration, isolatedVoice: nil)
    }

    /// Extract with an ALREADY-ISOLATED vocal signal supplied by the caller.
    ///
    /// Same as `extract(buffer:sampleRate:configuration:)` in every respect except one: when
    /// `isolatedVoice` is non-nil it is transcribed in a second Basic Pitch pass whose ONLY output that
    /// reaches the `Result` is `contour`. Passing a buffer here IS the request — `configuration.contourSource`
    /// is not consulted, and MCC does not run the AudioUnit itself.
    ///
    /// Use this overload when the app already holds a stem (it rendered one for another reason, or it must own
    /// the AudioUnit's thread/actor context). Otherwise prefer `Configuration.contourSource = .isolatedVoice`
    /// and let MCC own the isolation — MCC owns DSP, and the AU is available in MCC's deployment context
    /// (`macos(13.0)`/`ios(16.0)`, below MCC's macOS 14 / iOS 17 floors).
    ///
    /// - Parameters:
    ///   - buffer: Mono Float32 PCM samples of the FULL MIX. Every field except `contour` derives from this.
    ///   - sampleRate: Sample rate in Hz. `isolatedVoice` must be at this SAME rate.
    ///   - configuration: Optional tuning (see the three-argument overload).
    ///   - isolatedVoice: Mono Float32 samples of the isolated voice, time-aligned with `buffer`, or nil to
    ///     take the source from `configuration.contourSource`. Samples may exceed ±1.0 (measured peak 1.12);
    ///     nothing here normalizes them.
    /// - Returns: Bundled extraction result, with the mix-derived contour kept whenever the stem-derived one
    ///   is missing or fails the plausibility guard.
    public static func extract(
        buffer: [Float],
        sampleRate: Double,
        configuration: Configuration = .default,
        isolatedVoice: [Float]?
    ) -> Result {
        let duration = TimeInterval(buffer.count) / sampleRate

        // Near-silence guard. The Basic Pitch model emits a handful of phantom notes (and therefore a
        // spurious key/chord) on essentially-silent input — an all-zero buffer decoded to ~16 notes + a
        // key. If the buffer carries no meaningful signal, return an empty Result before running the
        // model. The floor is a peak amplitude of `silenceFloorPeak` (~-60 dBFS): orders of magnitude
        // below a real quiet nylon take (device captures peak ~0.30–0.52 on the device-test recordings),
        // so it only catches digital / near silence and never suppresses real fingerpicking.
        let peak = buffer.lazy.map { Swift.abs($0) }.max() ?? 0
        guard peak >= silenceFloorPeak else {
            return Result(chordSegments: [], key: nil, contour: [], detectedNotes: [], duration: duration, voicingDensity: 0)
        }

        guard let transcriber = sharedBasicPitchTranscriber,
              let transcription = try? transcriber.transcribe(buffer, sampleRate: sampleRate) else {
            // Model unavailable (or buffer empty) → never crash; emit a well-formed empty Result.
            return Result(chordSegments: [], key: nil, contour: [], detectedNotes: [], duration: duration, voicingDensity: 0)
        }
        let notes = transcription.notes
        let chordSegments = noteNativeChordSegments(notes: notes, duration: duration)   // FULL polyphony → note-native (the validated win)
        // detectedNotes = FULL polyphony. Sanctuary's melody-key inference AND its harmony timeline
        // both consume Result.detectedNotes; the skyline melodic reduction misread the key on
        // instrument input (a D–A take read C♯ minor instead of D/A major), because a single melodic
        // line drops the harmonic content the key/harmony stages need. Full polyphony fixes both with
        // no Sanctuary change. The contour stays a single melodic line via a locally-computed skyline.
        let detectedNotes = notes.map {
            DetectedNote(midiNote: $0.pitchMIDI,
                         onsetTime: $0.onsetTime,
                         duration: max(0.001, $0.duration),
                         confidence: min(1, max(0.1, $0.velocity)))
        }
        let mixContour = deriveContour(from: skyline(of: notes))                        // contour = melodic skyline (single line)
        let key = inferKey(from: chordSegments, fallbackNotes: detectedNotes)           // chord-based first, full-poly fallback

        // THE ONLY STEM-READING STEP. The optional second pass derives a contour from an isolated
        // vocal signal; `selectContour` decides whether it is good enough to reach the Result, and
        // keeps the mix-derived contour whenever it is not. Every other field above is already
        // computed from the mix and is not revisited — that separation is the feature's hard rule.
        let stemContour = isolatedVoiceContour(
            mix: buffer, sampleRate: sampleRate, configuration: configuration, provided: isolatedVoice
        )
        let contour = selectContour(mix: mixContour, stem: stemContour, duration: duration)

        // Take-type signal over the FULL polyphony (same `notes`) — not the melodic skyline.
        return Result(chordSegments: chordSegments, key: key, contour: contour, detectedNotes: detectedNotes, duration: duration, voicingDensity: voicingDensity(of: notes))
    }

    // MARK: - Vocal-stem contour side-channel (0.1.8)

    /// Resolve which isolated-voice samples the second pass should read, then transcribe them into a
    /// contour. Returns nil whenever there is no stem to read or the stem cannot produce one — every
    /// nil path falls back to exactly today's behavior, with no user-visible error (hard rule: FAIL
    /// SOFT, ALWAYS).
    ///
    /// Precedence: a caller-supplied `provided` buffer wins outright (passing one IS the request);
    /// otherwise `.isolatedVoice` asks MCC to run `VocalIsolator` on the mix; otherwise nil.
    private static func isolatedVoiceContour(
        mix: [Float],
        sampleRate: Double,
        configuration: Configuration,
        provided: [Float]?
    ) -> [ContourNote]? {
        let voice: [Float]
        if let provided {
            voice = provided
        } else if configuration.contourSource == .isolatedVoice {
            // Any throw — component missing, AU error, render failure — becomes nil.
            //
            // Cancellation lands here too. `extract` is synchronous and non-throwing, so it has no way
            // to report "aborted"; swallowing `.cancelled` means an expiring BGProcessingTask STOPS THE
            // RENDER promptly and this call finishes with today's mix contour, instead of grinding
            // through a render whose result nobody will read. The caller's own cancellation check, after
            // `extract` returns, still decides whether to keep the Result.
            guard let isolated = try? VocalIsolator.isolateVoice(mix, sampleRate: sampleRate) else { return nil }
            voice = isolated
        } else {
            return nil
        }
        return contourFromVoice(voice, sampleRate: sampleRate)
    }

    /// Second Basic Pitch pass over the isolated voice, reduced to a melodic skyline and differenced
    /// into a contour — the same two steps the mix path uses, so the two contours are the same kind of
    /// object and are interchangeable at the `Result`.
    ///
    /// The same `silenceFloorPeak` guard the mix path uses runs here first, and it matters MORE on a
    /// stem: isolation of a take with no singing leaves sparse transient residue that a pitch tracker
    /// reads as plausible phantom notes. Note the peak check is a floor, never a ceiling — the AU's
    /// output can exceed full scale (measured 1.12) and that is not an error.
    private static func contourFromVoice(_ voice: [Float], sampleRate: Double) -> [ContourNote]? {
        guard !voice.isEmpty, sampleRate > 0 else { return nil }
        let peak = voice.lazy.map { Swift.abs($0) }.max() ?? 0
        guard peak >= silenceFloorPeak else { return nil }
        guard let transcriber = sharedBasicPitchTranscriber,
              let transcription = try? transcriber.transcribe(voice, sampleRate: sampleRate) else { return nil }
        return deriveContour(from: skyline(of: transcription.notes))
    }

    /// **The plausibility guard.** Pure: choose between the mix-derived contour and the stem-derived
    /// one. The mix contour wins unless the stem contour exists AND clears
    /// `isPlausibleStemContour` — so a failed, empty, or degenerate isolation costs nothing but the
    /// render time.
    static func selectContour(
        mix: [ContourNote],
        stem: [ContourNote]?,
        duration: TimeInterval
    ) -> [ContourNote] {
        guard let stem, isPlausibleStemContour(stem, duration: duration) else { return mix }
        return stem
    }

    /// Is a stem-derived contour dense enough to be a sung line rather than the debris of a failed
    /// separation?
    ///
    /// Empty is rejected outright. Otherwise the test is note events per second of take, because
    /// "sparse" is only meaningful relative to duration: 20 events is a rich four-second hum and an
    /// empty four-minute song. The floor is `minimumStemContourNoteRate`.
    ///
    /// A DENSITY CEILING is deliberately absent. The mix's problem is that it is too dense (4.27
    /// events/s of noise on "6 Human"), so a ceiling is tempting — but a fast sung melisma is also
    /// dense, and no measurement yet separates the two. Adding one would silently discard real
    /// melodies; the guard only protects against the failure it has evidence for.
    static func isPlausibleStemContour(_ contour: [ContourNote], duration: TimeInterval) -> Bool {
        guard !contour.isEmpty else { return false }
        guard duration > 0 else { return false }
        return Double(contour.count) / duration >= minimumStemContourNoteRate
    }

    /// Minimum note events per second for a stem-derived contour to be believed.
    ///
    /// **PROVISIONAL, pending device tuning.** Anchored to the single measured pair (2026-08-08,
    /// "6 Human", 278.8 s): the isolated voice yields 394 events = 1.41/s, the mix yields 1190 = 4.27/s.
    /// 0.25/s is a fifth of the measured sung rate — deliberately far below it, because the guard's
    /// job is to catch a separation that produced NOTHING (silence, a wrong-model render, an
    /// instrument-only take that slipped the caller's gate), not to adjudicate musical density. One
    /// held note per four seconds still passes. Raising it trades false rejections (a sparse real hum
    /// silently falls back to the noisy mix contour, which is a quality loss the user cannot see)
    /// against false acceptances (phantom notes reach the melody line, which the user CAN see), so it
    /// should only move on device evidence from real takes, not on intuition.
    static let minimumStemContourNoteRate: Double = 0.25

    // MARK: - Basic Pitch note source

    /// Peak-amplitude floor (~-60 dBFS) below which `extract` treats the buffer as silence and returns
    /// an empty Result without running the model. Far below any real capture (the device-test nylon
    /// recordings peak at ~0.30–0.52), so it only catches digital / near silence.
    private static let silenceFloorPeak: Float = 1e-3

    /// Process-wide cached Basic Pitch transcriber. A Swift `static let` is initialized exactly once
    /// (lazily, thread-safe), so the bundled Core ML model is compiled + loaded a single time and
    /// reused across every `extract` call — no per-call recompile. `nil` if the model can't load
    /// (the path then degrades to a well-formed empty Result).
    private static let sharedBasicPitchTranscriber: BasicPitchTranscriber? = try? BasicPitchTranscriber()

    /// Note-native chord segments from full polyphony: 1.0 s window / 0.5 s hop (single window if the
    /// clip is shorter than one window), each window weighted by `overlapSeconds × velocity` per pitch
    /// class with the lowest sounding note as bass.
    ///
    /// **0.1.7 — sequence-decoded labeling (the 2026-08-07 ceiling-analysis fixes).** Windows are no
    /// longer labeled independently (per-window argmax made one melody-contaminated window its own
    /// segment — the "6 Human" chord-per-word churn and Am↔A / Em↔E quality flips). Instead:
    ///
    ///  1. `NoteChordIdentifier.candidateScores` produces each window's FULL candidate score vector;
    ///  2. `ChordSequenceDecoder.decode` Viterbi-decodes the window sequence with a
    ///     self-transition-favoring switch penalty (the literature's single biggest chord lever), so a
    ///     momentary contamination is absorbed while sustained real changes still win;
    ///  3. the **relative-minor guard** (`relativeMinorGuarded`, 2026-08-13) renames a SHORT decoded
    ///     minor/minor7 run to its relative major when the minor root never holds the bass and the
    ///     relative major earns the name (its triad sounding in the run, or an adjacent run already
    ///     carrying it) — the relative-minor-for-major substitution killer (7 of 8 wrong chords and
    ///     all 5 transition blips on the Rodanthe measurement);
    ///  4. the **bare-dyad guard** (`bareDyadGuarded`) renames a decoded major/minor run to the power
    ///     chord ("E5") when NONE of its windows carries a sounding third AND the take has other
    ///     chords to judge it against — a standalone fifth dyad no longer asserts MAJOR (the
    ///     phantom-E killer). A dyad window absorbed INTO a neighboring chord's run keeps that context
    ///     label — deferring to context is the guard's other honest outcome;
    ///  5. once a key is inferred from the decoded progression (chord-based only — a key needs a
    ///     progression to be trustworthy), a SECOND decode runs with a small non-diatonic penalty
    ///     (harmonic-minor V scored quasi-diatonic), so an artifact A-major inside A minor needs
    ///     genuine C♯ evidence while a real harmonic-minor E survives.
    ///
    /// The 0.1.1 `cleanupRuns` passes (edge trim + identical-flank flicker absorb) still run on the
    /// decoded runs — Viterbi supersedes the *generalized* short-run absorption that was considered
    /// for 9.4 (that idea stays OUT; the decode is the principled version of it), but the shipped
    /// conservative cleanup remains valid on the decoder's output.
    ///
    /// **Neutral on single-chord material by construction**, which the labeled bench requires: when
    /// every window argmaxes the same candidate the decode changes nothing, one run means no second
    /// pass (no progression → no key) and no dyad guard (sole runs are exempt). Verified 2026-08-08
    /// against a pristine-HEAD worktree — GADA 100.0/100.0 and TaylorNylon 99.1/99.1 root/exact on
    /// both, same single C→A confusion.
    private static func noteNativeChordSegments(notes: [TranscribedNote], duration: TimeInterval) -> [ChordSegment] {
        guard !notes.isEmpty, duration > 0 else { return [] }
        let windowLen = 1.0, hop = 0.5

        var starts: [Double] = []
        if duration <= windowLen { starts = [0] }
        else { var s = 0.0; while s < duration { starts.append(s); s += hop } }

        // Per-window weighted pitch-class histogram + bass (the evidence; unchanged from 0.1.0).
        var bins: [[Double]] = []
        var basses: [Int?] = []
        for s in starts {
            let e = min(s + windowLen, duration)
            var b = [Double](repeating: 0, count: 12)
            var lowest = Int.max
            for n in notes {
                let overlap = max(0, min(n.onsetTime + n.duration, e) - max(n.onsetTime, s))
                guard overlap > 0 else { continue }
                b[((n.pitchMIDI % 12) + 12) % 12] += overlap * max(0, n.velocity)
                if n.pitchMIDI < lowest { lowest = n.pitchMIDI }
            }
            bins.append(b)
            basses.append(lowest == Int.max ? nil : ((lowest % 12) + 12) % 12)
        }

        // Full candidate score vector per window (nil where the window has no usable content —
        // decode stretches never claim continuity across those).
        let scoreVectors: [[Double]?] = (0..<starts.count).map {
            NoteChordIdentifier.candidateScores(weightedPitchClasses: bins[$0], bassPitchClass: basses[$0])
        }

        // FIRST PASS — context decode, runs, dyad guard, conservative cleanup.
        let labels1 = ChordSequenceDecoder.decode(windows: scoreVectors)
        let runs1 = decodedRuns(labels: labels1, scoreVectors: scoreVectors,
                                bins: bins, basses: basses, starts: starts, duration: duration)
        let firstSegments = finalizeSegments(runs: runs1, duration: duration)

        // SECOND PASS — key-aware prior, only when the decoded progression itself supports a key
        // (≥2 distinct chords → ProgressionAnalyzer). A melody-fallback key is not evidence enough
        // to re-bias chord naming (and single-chord bench fixtures stay structurally exempt).
        guard let key = chordBasedKey(from: firstSegments) else { return firstSegments }
        let labels2 = ChordSequenceDecoder.decode(
            windows: scoreVectors,
            candidatePenalty: ChordSequenceDecoder.nonDiatonicPenalty(for: key))
        if labels2 == labels1 { return firstSegments }
        let runs2 = decodedRuns(labels: labels2, scoreVectors: scoreVectors,
                                bins: bins, basses: basses, starts: starts, duration: duration)
        return finalizeSegments(runs: runs2, duration: duration)
    }

    /// Decoded window labels → cleaned chord runs: build per-window chords, collapse identical
    /// consecutive names into runs (tracking each run's window range), apply the bare-dyad guard at
    /// run level, then the 0.1.1 conservative cleanup (edge trim + identical-flank flicker absorb).
    private static func decodedRuns(labels: [Int?], scoreVectors: [[Double]?],
                                    bins: [[Double]], basses: [Int?],
                                    starts: [Double], duration: TimeInterval)
        -> [(start: Double, chord: Chord, conf: Double)] {
        // Per-window chord from the decoded candidate (conf = that window's clamped candidate score,
        // matching identify's confidence semantics).
        var win: [(start: Double, chord: Chord?, conf: Double)] = []
        for (i, label) in labels.enumerated() {
            guard let label, let vec = scoreVectors[i],
                  let cand = NoteChordIdentifier.candidate(at: label) else {
                win.append((starts[i], nil, 0)); continue
            }
            let conf = min(1.0, max(0.0, vec[label]))
            let chordNotes = cand.quality.intervals.compactMap { NoteName(rawValue: (cand.root.rawValue + $0) % 12) }
            win.append((starts[i], Chord(root: cand.root, quality: cand.quality, confidence: conf, notes: chordNotes), conf))
        }

        // Collapse consecutive identical chord names into runs, remembering the window range so the
        // dyad guard can ask "did ANY window of this run actually sound a third?".
        var runs: [(start: Double, chord: Chord, conf: Double, windows: ClosedRange<Int>)] = []
        var i = 0
        while i < win.count {
            guard let chord = win[i].chord else { i += 1; continue }
            var j = i
            while j + 1 < win.count, let next = win[j + 1].chord, next.displayName == chord.displayName { j += 1 }
            let confs = win[i...j].map { $0.conf }
            runs.append((win[i].start, chord, confs.reduce(0, +) / Double(confs.count), i...j))
            i = j + 1
        }

        // Relative-minor guard (run level) — see `relativeMinorGuarded`. Runs BEFORE the bare-dyad
        // guard: a rename target always carries a sounding third (its evidence test requires one),
        // so the dyad guard never re-fires on a renamed run.
        let minorGuarded = relativeMinorGuarded(runs: runs, bins: bins, basses: basses,
                                                scoreVectors: scoreVectors)

        // Bare-dyad guard (run level) — see `bareDyadGuarded`.
        let guarded = bareDyadGuarded(runs: minorGuarded, bins: bins, basses: basses)

        // Clean up pick-attack/release edge transients and same-root sus/added flicker (0.1.1).
        // Its re-collapse also merges adjacent runs the guards may have renamed to one name.
        return cleanupRuns(guarded, duration: duration)
    }

    /// Run-length ceiling for the relative-minor guard, in windows (0.5 s hop → ≤ ~1.5 s of audio).
    /// Every wrong minor run in the 2026-08-13 Rodanthe measurement was 1–3 windows; the shortest
    /// REAL minor call anywhere in the corpus that lacks its own bass (Kill Devil Hills' F♯m7 at
    /// 13.5 s, F♯ bass throughout) is 4. Sustained minors are exactly the calls that scored 5/5,
    /// so the guard never reads past this line.
    static let relativeMinorGuardMaxWindows = 3

    /// Bass-evidence bar for a short minor call: the minor ROOT must be the detected bass (the
    /// window's lowest sounding note) in at least this many of the run's windows — at the 0.5 s hop,
    /// two windows ≈ the root holding the bass for about a beat at this repertoire's tempos. Across
    /// the 2026-08-13 corpus sweep every wrong minor run had 0 or 1 root-bass windows and every kept
    /// real one had ≥ 2 (Kill Devil Hills' F♯m7 at 55.5 s: exactly 2; Romance de Amor's Am7: 8).
    static let relativeMinorGuardMinBassWindows = 2

    /// **The relative-minor guard (the 2026-08-13 Rodanthe fix).** Relative-minor-for-major
    /// substitution was the measured dominant error class on Chris's capo-2 fingerpicked take:
    /// 7 of 8 wrong chords and all 5 transition blips renamed a major to its relative minor —
    /// A heard as F♯m(7), D as Bm(7) — while every sustained chord scored 5/5.
    ///
    /// **The mechanism (per-window evidence, `windbg` sweep 2026-08-13):** a transition window
    /// BLENDS two adjacent majors (A: A-C♯-E ringing into D: D-F♯-A), and the relative minor 7 is
    /// the four-note candidate that covers the blend best — F♯m7 = the whole A triad plus D's F♯ —
    /// so it outscores either honest major on coverage alone. That is also why confidence cannot
    /// filter it (wrong calls averaged 0.75 vs 0.78 for right ones, one wrong call at 0.96): the
    /// coverage is genuinely high. The same sweep killed the weight-ratio idea — wrong runs reached
    /// a minor-root/relative-root weight ratio of 0.87 (the F♯ is REAL, it belongs to D) while Kill
    /// Devil Hills' genuine F♯m7 at 55.5 s sat at 0.28 (A-C♯-E over an F♯ bass). What separated
    /// every wrong call from every real one was the BASS: a real short minor puts its root under
    /// the chord for at least a beat; a substitution artifact never does (≤ 1 window, usually 0).
    ///
    /// A minor/minor7 run is therefore renamed to its relative major when ALL of:
    ///  1. it is SHORT (≤ `relativeMinorGuardMaxWindows` windows — the defect's measured extent;
    ///     sustained minors, which score 5/5, are structurally exempt);
    ///  2. the minor ROOT is NOT bass-supported (fewer than `relativeMinorGuardMinBassWindows`
    ///     windows with the root as the detected bass);
    ///  3. the relative major actually EARNS the name, one of two ways:
    ///     - **cover evidence**: the run's own summed histogram sounds the full relative-major
    ///       triad (the blend case — needed because the substitution often STEALS the entire true
    ///       segment, e.g. Rodanthe's chorus A at 45.5/51.5/63.5 s decoded wholly as F♯m7 flanked
    ///       by D, so no relative-major neighbor exists to defer to); or
    ///     - **a relative-major NEIGHBOR**: an adjacent run rooted on the relative major whose
    ///       tones cover everything this run sounded beyond its claimed root (the dyad case —
    ///       Rodanthe's D+F♯ windows decoded Bm with NO B sounding at all; renamed to the
    ///       neighbor's own chord so the cleanup re-collapse absorbs the blip).
    ///    Without either, the run is left alone — Romance de Amor's 0.5 s Em boundary blip sits on
    ///    a B-dominated window with no D anywhere; renaming it to a G that is not in the piece
    ///    would trade an in-key blip for an out-of-progression one.
    ///
    /// The rename prefers the neighbor's chord over the plain relative-major triad when both
    /// qualify (context labels merge; a standalone segment only appears when the take really
    /// changed chords there). Confidence is the run windows' own clamped candidate score for the
    /// renamed chord — the shared scoring formula, comparable to every decoded run.
    ///
    /// **Never touches a sole run** (`runs.count >= 2`), same conservative posture as
    /// `bareDyadGuarded` and `cleanupRuns` — which also keeps the single-chord bench fixtures
    /// (GADA / TaylorNylon) structurally exempt.
    ///
    /// Measured 2026-08-13 (Mac, release, `take-probe`, scored against the songs' own sheets —
    /// sheets are SHAPES at capo 2, scoring transposed to sounding):
    ///  - **Rodanthe**: all 11 substituted minor segments gone (the 7 wrong chords AND the 5
    ///    transition blips), each resolving to the sheet's sounding D/G/A; wrong-root events
    ///    12 → 1 (the surviving one is a trailing 0.88 s Esus2 — a different defect class);
    ///    event accuracy 34/46 (73.9%) → 37/38 (97.4%).
    ///  - **Kill Devil Hills**: real Bm runs and both bass-holding F♯m7s kept; three 0.5 s F♯m7
    ///    ring-over blips absorb into the A the sheet has there; key B minor → D major, matching
    ///    the sheet's C-shape tonic at capo 2.
    ///  - **Romance de Amor**: byte-identical — Am7 (0.64) and B7 (0.39) untouched.
    ///  - **Broken Man**: ten 0.5 s Gm(7) ring-over blips (G is A♯'s 6th) absorb into the
    ///    adjacent A♯; the bass-supported Gm7s at 9.0 s and 51.0 s stay, and three more stay
    ///    for want of rename evidence; key C minor unchanged.
    ///  - **Instrumental in D**: the 0.31-confidence Bm7 at 33.5 s absorbs into the D drone; the
    ///    sustained Bm7 sections stay.
    ///  - GADA / TaylorNylon single-chord benches: structurally exempt, numbers unchanged.
    ///
    /// Pure and internal so it is unit-testable without audio (`ChordSequenceDecoderTests`).
    /// `bins[w]` / `basses[w]` / `scoreVectors[w]` are the window-`w` evidence the runs were
    /// decoded from; window ranges are preserved so `bareDyadGuarded` still sees them.
    static func relativeMinorGuarded(
        runs: [(start: Double, chord: Chord, conf: Double, windows: ClosedRange<Int>)],
        bins: [[Double]], basses: [Int?], scoreVectors: [[Double]?])
        -> [(start: Double, chord: Chord, conf: Double, windows: ClosedRange<Int>)] {
        guard runs.count >= 2 else { return runs }   // sole run: no context, never renamed

        var out = runs
        for (k, r) in runs.enumerated() {
            guard r.chord.quality == .minor || r.chord.quality == .minor7,
                  r.windows.count <= relativeMinorGuardMaxWindows else { continue }

            // (2) Bass support: a real short minor holds its root in the bass; an artifact doesn't.
            let m = r.chord.root.rawValue
            let rootBassWindows = r.windows.filter { basses[$0] == m }.count
            guard rootBassWindows < relativeMinorGuardMinBassWindows else { continue }

            let relRoot = (m + 3) % 12

            // (3a) Cover evidence: the full relative-major triad sounds in the run's summed windows
            // AND the relative-major root touches the detected bass somewhere in the run. The triad
            // test alone is not enough — a minor→minor boundary window also contains a relative-major
            // triad (Romance de Amor's Em→Am handoff blends {E,G,B}+{A,C,E} ⊇ the C triad, and
            // renaming that window to a C the piece never plays trades an honest boundary for an
            // out-of-progression name). Every genuine substitution in the 2026-08-13 sweep had the
            // relative-major root in the bass of at least one run window (it was the chord actually
            // being played); the Romance boundary never does.
            var summed = [Double](repeating: 0, count: 12)
            for w in r.windows {
                for pc in 0..<12 { summed[pc] += bins[w][pc] }
            }
            let relRootInBass = r.windows.contains { basses[$0] == relRoot }
            let coverEvidence = relRootInBass
                && NoteChordIdentifier.majorTriadPresent(root: relRoot, weightedPitchClasses: summed)

            // (3b) A relative-major neighbor whose tones cover everything beyond the claimed root.
            let upperTones = Set(r.chord.quality.intervals.dropFirst().map { (m + $0) % 12 })
            var neighbor: Chord?
            for nk in [k - 1, k + 1] where nk >= 0 && nk < runs.count {
                let n = runs[nk].chord
                guard n.root.rawValue == relRoot else { continue }
                let neighborTones = Set(n.quality.intervals.map { (relRoot + $0) % 12 })
                if upperTones.isSubset(of: neighborTones) { neighbor = n; break }
            }

            // Rename target: the neighbor's own chord when one qualifies (context labels merge),
            // else the plain relative-major triad the cover evidence named.
            let target: (root: NoteName, quality: ChordQuality)?
            if let neighbor { target = (neighbor.root, neighbor.quality) }
            else if coverEvidence { target = NoteName(rawValue: relRoot).map { ($0, .major) } }
            else { target = nil }
            guard let target,
                  let qualityIndex = NoteChordIdentifier.candidateQualities.firstIndex(of: target.quality)
            else { continue }

            // Confidence from the shared formula: the run windows' clamped score for the new name.
            let candidateIndex = target.root.rawValue * NoteChordIdentifier.candidateQualities.count + qualityIndex
            let windowScores = r.windows.compactMap { scoreVectors[$0].map { min(1.0, max(0.0, $0[candidateIndex])) } }
            let conf = windowScores.isEmpty ? r.conf : windowScores.reduce(0, +) / Double(windowScores.count)

            let notes = target.quality.intervals.compactMap { NoteName(rawValue: (target.root.rawValue + $0) % 12) }
            out[k] = (r.start,
                      Chord(root: target.root, quality: target.quality, confidence: conf, notes: notes),
                      conf, r.windows)
        }
        return out
    }

    /// **The bare-dyad guard (0.1.7).** A decoded major/minor run whose windows never sound EITHER
    /// third is a bare root+fifth dyad wearing a deterministic default — major sorts first in
    /// `NoteChordIdentifier.candidateQualities` and replacement is strictly-greater, so a fifth dyad
    /// falls out as MAJOR on candidate ordering alone, not on evidence. Such a run is renamed to the
    /// honest `.power` naming ("E5", not "E"): the phantom-standalone-E/A killer from the 2026-08-07
    /// "6 Human" ceiling analysis (Sanctuary BACKLOG chord-ceiling evidence).
    ///
    /// **The guard needs context to be honest, so it never touches a SOLE run** — the same
    /// conservative posture `cleanupRuns` takes ("never touches a sole run"). Measured 2026-08-08 on
    /// the labeled TaylorNylon bench: four of the nineteen sustained G takes (G_015–G_018) transcribe
    /// as a pure D+G dyad with NO B in any window, because Basic Pitch misses the third on a nylon
    /// string with weak 3rd harmonics and sparse fingerpicked voicings — the standing instrument
    /// constraint in Sanctuary's CLAUDE.md ("All audio analysis thresholds must work with this
    /// instrument"). Ground truth on all four is G major, so an unconditional guard names them "G5"
    /// and costs 3.7 points of bench exact accuracy (99.1% → 95.4%). When the take IS one chord there
    /// is no context to judge a missing third against and a transcription miss is the likelier
    /// explanation; when the run stands among OTHER chords — exactly the phantom's shape — the dyad
    /// reading is the honest one. This is also why the guard lives here and not in
    /// `NoteChordIdentifier.identify`: a single histogram carries no context to make the call with.
    ///
    /// A dyad window the decode absorbed INTO a flanking chord's run never reaches here as its own
    /// run — context already named it, which is the guard's other honest outcome.
    ///
    /// Pure and internal so it is unit-testable without audio (`ChordSequenceDecoderTests`).
    /// `bins[w]` / `basses[w]` are the window-`w` evidence the runs were decoded from.
    static func bareDyadGuarded(runs: [(start: Double, chord: Chord, conf: Double, windows: ClosedRange<Int>)],
                                bins: [[Double]], basses: [Int?])
        -> [(start: Double, chord: Chord, conf: Double)] {
        let plain = runs.map { (start: $0.start, chord: $0.chord, conf: $0.conf) }
        guard runs.count >= 2 else { return plain }   // sole run: no context, never renamed

        var guarded: [(start: Double, chord: Chord, conf: Double)] = []
        for (k, r) in runs.enumerated() {
            if r.chord.quality == .major || r.chord.quality == .minor {
                let rootPC = r.chord.root.rawValue
                let anyThird = r.windows.contains {
                    NoteChordIdentifier.thirdPasses(root: rootPC, weightedPitchClasses: bins[$0])
                }
                if !anyThird {
                    let scored = r.windows.compactMap {
                        NoteChordIdentifier.powerChord(root: rootPC, weightedPitchClasses: bins[$0], bassPitchClass: basses[$0])
                    }
                    if let firstScored = scored.first {
                        let meanConf = scored.map { $0.confidence }.reduce(0, +) / Double(scored.count)
                        guarded.append((r.start, firstScored.chord, meanConf))
                        continue
                    }
                }
            }
            guarded.append(plain[k])
        }
        return guarded
    }

    /// Contiguous, non-overlapping `ChordSegment`s from cleaned runs (next run's start, or duration
    /// for the last, as the end time).
    private static func finalizeSegments(runs: [(start: Double, chord: Chord, conf: Double)],
                                         duration: TimeInterval) -> [ChordSegment] {
        runs.enumerated().map { (k, r) in
            let end = k + 1 < runs.count ? runs[k + 1].start : duration
            // Reuse the existing `.classifier` DetectionMethod case — the enum is frozen for Sanctuary;
            // a dedicated `.noteNative` case is a later additive option.
            return ChordSegment(startTime: r.start, endTime: end, chord: r.chord, confidence: r.conf, detectionMethod: .classifier)
        }
    }

    /// Chord-based key only (the second decode pass's gate): ≥2 distinct decoded chords →
    /// `ProgressionAnalyzer.inferKey`; nil otherwise. Mirrors `inferKey`'s first branch WITHOUT the
    /// melody fallback — a fallback key isn't progression evidence and must not re-bias chord naming.
    private static func chordBasedKey(from segments: [ChordSegment]) -> MusicalKey? {
        guard segments.count >= 2 else { return nil }
        let chords = segments.map { $0.chord }
        guard Set(chords).count >= 2 else { return nil }
        return ProgressionAnalyzer.inferKey(from: chords)
    }

    /// Note-native segment cleanup (0.1.1): trim weak pick-attack/release edge runs and absorb a single
    /// sus/added-tone "flicker" run flanked by an identical same-root base (e.g. Am–Asus2–Am → Am).
    /// Conservative by construction — it never touches a sole run, never trims a long or confident run,
    /// and only merges a variant when both neighbours are the *same* chord, so real chord changes survive.
    private static func cleanupRuns(_ input: [(start: Double, chord: Chord, conf: Double)],
                                    duration: TimeInterval) -> [(start: Double, chord: Chord, conf: Double)] {
        var runs = input
        func span(_ idx: Int) -> Double { (idx + 1 < runs.count ? runs[idx + 1].start : duration) - runs[idx].start }

        // (1) Edge trim: drop a leading/trailing run that is short (≤ one window-hop) AND low-confidence.
        // Bench fixtures are a single sustained chord (one long run), so they are never edge-trimmed.
        let edgeMaxSpan = 0.75, edgeMaxConf = 0.7
        if runs.count >= 2, span(0) <= edgeMaxSpan, runs[0].conf < edgeMaxConf { runs.removeFirst() }
        if runs.count >= 2, span(runs.count - 1) <= edgeMaxSpan, runs[runs.count - 1].conf < edgeMaxConf { runs.removeLast() }

        // (2) Flicker absorb: a single interior run that shares its root with an identical chord on BOTH
        // sides becomes that chord (Am–Asus2–Am → Am–Am–Am). Different flanks or a different root are
        // left alone, so genuine chord changes are preserved.
        if runs.count >= 3 {
            for idx in 1..<(runs.count - 1) {
                let prev = runs[idx - 1].chord, cur = runs[idx].chord, next = runs[idx + 1].chord
                if prev.displayName == next.displayName, cur.root == prev.root, cur.displayName != prev.displayName {
                    runs[idx].chord = prev
                }
            }
        }

        // (3) Re-collapse consecutive identical chord names (earliest start, count-weighted mean conf).
        var merged: [(start: Double, chord: Chord, confSum: Double, n: Int)] = []
        for r in runs {
            if let last = merged.last, last.chord.displayName == r.chord.displayName {
                merged[merged.count - 1].confSum += r.conf
                merged[merged.count - 1].n += 1
            } else {
                merged.append((r.start, r.chord, r.conf, 1))
            }
        }
        return merged.map { ($0.start, $0.chord, $0.confSum / Double($0.n)) }
    }

    /// First-pass melodic reduction: the highest-pitched sounding note at each instant, emitted as a
    /// monophonic `[DetectedNote]` (preserves the field's "monophonic melodic events" semantics).
    private static func skyline(of notes: [TranscribedNote]) -> [DetectedNote] {
        guard !notes.isEmpty else { return [] }
        var boundsSet = Set<Double>()
        for n in notes { boundsSet.insert(n.onsetTime); boundsSet.insert(n.onsetTime + n.duration) }
        let times = boundsSet.sorted()
        guard times.count >= 2 else { return [] }

        // Highest active note per slice (sampled at the slice midpoint).
        var sliceTop: [(midi: Int, vel: Double)?] = []
        for k in 0..<(times.count - 1) {
            let mid = (times[k] + times[k + 1]) / 2
            var top: TranscribedNote?
            for n in notes where n.onsetTime <= mid && mid < n.onsetTime + n.duration {
                if top == nil || n.pitchMIDI > top!.pitchMIDI { top = n }
            }
            sliceTop.append(top.map { ($0.pitchMIDI, $0.velocity) })
        }

        // Merge consecutive slices that share a top pitch into single monophonic notes.
        var out: [DetectedNote] = []
        var k = 0
        while k < sliceTop.count {
            guard let cur = sliceTop[k] else { k += 1; continue }
            var j = k
            while j + 1 < sliceTop.count, let nxt = sliceTop[j + 1], nxt.midi == cur.midi { j += 1 }
            out.append(DetectedNote(
                midiNote: cur.midi,
                onsetTime: times[k],
                duration: max(0.001, times[j + 1] - times[k]),
                confidence: min(1, max(0.1, cur.vel))
            ))
            k = j + 1
        }
        return out
    }

    // MARK: - Voicing density (take-type signal)

    /// Mean number of simultaneously-sounding DISTINCT PITCH CLASSES over the buffer's sounding time.
    /// ~1.0 for a monophonic line (a sung/hummed take); higher when notes stack (a played/strummed take).
    /// Distinct pitch classes (not raw note count) so octave doublings/overtones don't inflate it.
    ///
    /// A take-type *measure*, not a verdict: MCC ships the number; the sung/played threshold is the
    /// consumer's policy (mirrors `KeyCandidate.score` vs `HarmonyKeyGate.minScore`). Pure +
    /// deterministic by construction. Computed over the FULL polyphony (not the melodic skyline).
    static func voicingDensity(of notes: [TranscribedNote]) -> Double {
        guard !notes.isEmpty else { return 0 }

        // Boundary times: every note's onset and offset, sorted + de-duplicated.
        var boundarySet = Set<Double>()
        for n in notes {
            boundarySet.insert(n.onsetTime)
            boundarySet.insert(n.onsetTime + n.duration)
        }
        let bounds = boundarySet.sorted()
        guard bounds.count >= 2 else { return 0 }

        var weighted = 0.0   // Σ (distinct PCs) × (slice length), over slices with ≥1 active note
        var covered = 0.0    // Σ (slice length), over those same slices — the take's sounding time
        for k in 0..<(bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            guard b > a else { continue }
            var pcs = Set<Int>()
            for n in notes where n.onsetTime < b && n.onsetTime + n.duration > a {
                pcs.insert(((n.pitchMIDI % 12) + 12) % 12)
            }
            if !pcs.isEmpty {
                weighted += Double(pcs.count) * (b - a)
                covered += (b - a)
            }
        }
        return covered > 0 ? weighted / covered : 0
    }

    // MARK: - Configuration

    /// Tuning parameters for audio extraction.
    ///
    /// Most of these fields tuned the removed YIN + FFT-chroma DSP pipeline and are now vestigial under
    /// the Basic Pitch front-end. They are retained so existing call sites (`Configuration()` /
    /// `.default`) stay source-compatible; the Basic Pitch path does not read them. `contourSource`
    /// (added 0.1.8) is the exception — it IS read.
    public struct Configuration: Equatable, Hashable, Sendable {

        /// Where the melodic `contour` is traced from. Every OTHER field of `Result` reads the full mix
        /// regardless of this setting.
        ///
        /// **Why the option exists (measured 2026-08-08, "6 Human", approved by Chris the same day).**
        /// A contour traced from a mix is not a melody: the mix yields 1190 note events at 4.27/s with
        /// 11% stepwise motion — the signature of noise; the isolated voice yields 394 at 1.41/s with
        /// 54% stepwise motion — a singable line.
        ///
        /// **Why it is not the default, and never becomes one automatically.** Isolation must run only
        /// on takes that actually contain singing. Measured, isolating an instrument-only take leaves
        /// sparse transient residue peaking at -5 dBFS that a pitch tracker reads as plausible phantom
        /// notes that were never sung. That decision is the CONSUMER's, made from MIX-derived signals
        /// (the app's take-type routing: `Result.voicingDensity` plus transcript presence) — MCC
        /// deliberately does not invent a second threshold here, for the same reason `voicingDensity`
        /// ships as a number and not a verdict: the sung/played boundary is app policy. Setting
        /// `.isolatedVoice` asserts "this take contains singing"; MCC takes that assertion at its word.
        public enum ContourSource: String, Equatable, Hashable, Sendable, CaseIterable {
            /// Today's behavior, unchanged: the contour is the melodic skyline of the single mix pass.
            case mix
            /// Run `VocalIsolator` on the mix, transcribe the isolated voice in a second Basic Pitch
            /// pass, and take the contour from that — falling back to `.mix` on any failure or an
            /// implausible result. Costs one AU render (measured 82-97x realtime mono, 43-45x stereo on
            /// an iPhone 17 Pro Max) plus one extra Basic Pitch pass. The isolated audio is transient:
            /// it is never returned, cached, or written anywhere.
            case isolatedVoice
        }

        /// Minimum gap between successive onsets in milliseconds. Default 500.
        public let onsetMinGapMs: Double
        /// Energy multiplier for onset detection threshold. Default 2.0.
        public let onsetEnergyMultiplier: Float
        /// Absolute minimum RMS energy for onset detection. Default 0.005.
        public let onsetEnergyFloor: Float
        /// Chroma analysis window size in samples. Default 8192.
        public let chromaWindowSize: Int
        /// Chroma analysis hop size in samples. Default 4096 (50% overlap).
        public let chromaHopSize: Int
        /// Early-frame attack skip in frames. Default 2 (skip first 2 frames per segment for attack settling).
        public let earlyFrameAttackSkip: Int
        /// Early-frame averaging window size in frames. Default 8.
        public let earlyFrameWindowSize: Int
        /// Minimum extraction confidence (0–1). Default 0.25 with ≥5 frames, 0.35 otherwise.
        public let extractionMinConfidence: Double
        /// Silence threshold (RMS) for noise calibration. Default 0.001 (-60dB).
        public let silenceThreshold: Float
        /// Where the melodic contour is traced from. Default `.mix` — existing callers are
        /// byte-identical in behavior. See `ContourSource`.
        public let contourSource: ContourSource

        /// Creates a Configuration with custom parameters.
        ///
        /// `contourSource` is appended LAST with a default so every existing call site — positional or
        /// labeled, full or partial — keeps compiling and keeps behaving identically.
        public init(
            onsetMinGapMs: Double = 500,
            onsetEnergyMultiplier: Float = 2.0,
            onsetEnergyFloor: Float = 0.005,
            chromaWindowSize: Int = 8192,
            chromaHopSize: Int = 4096,
            earlyFrameAttackSkip: Int = 2,
            earlyFrameWindowSize: Int = 8,
            extractionMinConfidence: Double = 0.25,
            silenceThreshold: Float = 0.001,
            contourSource: ContourSource = .mix
        ) {
            self.onsetMinGapMs = onsetMinGapMs
            self.onsetEnergyMultiplier = onsetEnergyMultiplier
            self.onsetEnergyFloor = onsetEnergyFloor
            self.chromaWindowSize = chromaWindowSize
            self.chromaHopSize = chromaHopSize
            self.earlyFrameAttackSkip = earlyFrameAttackSkip
            self.earlyFrameWindowSize = earlyFrameWindowSize
            self.extractionMinConfidence = extractionMinConfidence
            self.silenceThreshold = silenceThreshold
            self.contourSource = contourSource
        }

        /// Default configuration.
        public static let `default` = Configuration()
    }

    // MARK: - Result

    /// Complete extraction result from audio analysis.
    public struct Result: Equatable, Hashable, Sendable {
        /// Detected chord segments in playback order.
        public let chordSegments: [ChordSegment]
        /// Inferred musical key from chord progression or pitch class distribution.
        public let key: MusicalKey?
        /// Melodic contour as a sequence of pitched note events with absolute timing.
        public let contour: [ContourNote]
        /// Individual detected notes (pre-contour, raw monophonic events).
        public let detectedNotes: [DetectedNote]
        /// Total duration of the analyzed buffer in seconds.
        public let duration: TimeInterval
        /// Take-type signal: the mean number of simultaneously-sounding DISTINCT PITCH CLASSES over the
        /// take's sounding time, from the Basic Pitch polyphony. ~1.0 for a monophonic/sung take; higher
        /// for a polyphonic/played one. Lets a consumer route sung vs played (e.g. suppress "chords heard"
        /// on a bare sung line); the sung/played threshold is the consumer's policy, not MCC's. `0` for an
        /// empty/silence-guarded result.
        public let voicingDensity: Double

        /// Creates an extraction result.
        public init(
            chordSegments: [ChordSegment],
            key: MusicalKey?,
            contour: [ContourNote],
            detectedNotes: [DetectedNote],
            duration: TimeInterval,
            voicingDensity: Double
        ) {
            self.chordSegments = chordSegments
            self.key = key
            self.contour = contour
            self.detectedNotes = detectedNotes
            self.duration = duration
            self.voicingDensity = voicingDensity
        }
    }

    // MARK: - ChordSegment

    /// A detected chord segment with timing and confidence.
    public struct ChordSegment: Equatable, Hashable, Sendable, Identifiable {
        /// Unique identifier for this segment.
        public let id: UUID
        /// Onset time in seconds from buffer start.
        public let startTime: TimeInterval
        /// Offset time (end) in seconds from buffer start.
        public let endTime: TimeInterval
        /// Detected chord.
        public let chord: Chord
        /// Detection confidence (0.0–1.0).
        public let confidence: Double
        /// Which detection path produced this result (template matching, interval detection, multi-path agreement).
        public let detectionMethod: DetectionMethod

        /// Creates a chord segment.
        public init(
            id: UUID = UUID(),
            startTime: TimeInterval,
            endTime: TimeInterval,
            chord: Chord,
            confidence: Double,
            detectionMethod: DetectionMethod
        ) {
            self.id = id
            self.startTime = startTime
            self.endTime = endTime
            self.chord = chord
            self.confidence = confidence
            self.detectionMethod = detectionMethod
        }

        /// Chord detection method.
        public enum DetectionMethod: String, Equatable, Hashable, Sendable, CaseIterable {
            case classifier
            case interval
            case agreement
        }
    }

    // MARK: - Private helpers

    private static func deriveContour(from detectedNotes: [DetectedNote]) -> [ContourNote] {
        guard !detectedNotes.isEmpty else { return [] }

        var contour: [ContourNote] = []

        // First note: pitchSemitoneStep=0, parsonsCode=.repeat_
        contour.append(ContourNote(
            pitchSemitoneStep: 0,
            parsonsCode: .repeat_,
            onsetTime: detectedNotes[0].onsetTime,
            duration: detectedNotes[0].duration
        ))

        // Successive notes: difference MIDI values
        for i in 1..<detectedNotes.count {
            let step = detectedNotes[i].midiNote - detectedNotes[i - 1].midiNote
            let direction: ParsonsCode
            if step > 0 {
                direction = .up
            } else if step < 0 {
                direction = .down
            } else {
                direction = .repeat_
            }

            contour.append(ContourNote(
                pitchSemitoneStep: step,
                parsonsCode: direction,
                onsetTime: detectedNotes[i].onsetTime,
                duration: detectedNotes[i].duration
            ))
        }

        return contour
    }

    private static func inferKey(from chordSegments: [ChordSegment], fallbackNotes: [DetectedNote]) -> MusicalKey? {
        // First try: chord-based inference from segment progression
        if chordSegments.count >= 2 {
            let chords = chordSegments.map { $0.chord }
            let distinctChords = Set(chords)
            if distinctChords.count >= 2, let key = ProgressionAnalyzer.inferKey(from: chords) {
                return key
            }
        }

        // Fallback: pitch-class-based inference from detected notes
        if !fallbackNotes.isEmpty {
            let candidates = MelodyKeyInference.infer(from: fallbackNotes, maxCandidates: 1)
            return candidates.first?.key
        }

        return nil
    }
}
