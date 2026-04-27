# MusicCraftCore — Codex

## Identity

**Name:** MusicCraftCore (MCC)

**Purpose:** A shared DSP, music theory, and audio analysis library consumed as a Swift Package dependency by Cantus, Guitar Atlas, Sanctuary, and other Mossgrove music apps. Extracted incrementally from Cantus with each release corresponding to a feature area.

**Tagline:** Reusable algorithms and data for music understanding — portable across the studio.

## What MCC Is

MusicCraftCore is the Mossgrove portfolio's on-device Music Information Retrieval (MIR) layer. MIR is the established academic field concerned with extracting structured musical descriptors from audio — pitch, chord, key, beat, tempo, structural segmentation, timbre, lyric content, and higher-order musical features. Reference libraries in the field include Essentia (UPF Barcelona, AGPL v3 + commercial), aubio (GPL v3), and librosa (Python, ISC). MCC fills the same role for Mossgrove that those libraries fill for their respective ecosystems.

MCC supports both real-time and offline analysis. Real-time analysis processes audio frame-by-frame at 60 Hz for live UI surfaces — chord display, tuner, pitch contour, attack detection. Offline analysis processes a complete audio buffer with multi-frame averaging, segmentation, and refined detection. Many algorithms have both modes, and that's the right pattern: ChordDetector already does, AudioExtractor (planned for 0.0.8) extends this duality to the full pipeline. A meaningful share of MCC's real-time infrastructure has already shipped (DSP primitives, ChordDetection); offline pipelines are the active extraction frontier.

Why MCC exists as a custom library rather than depending on existing MIR tooling: every comprehensive open-source MIR library currently available with iOS support is licensed under viral copyleft terms (Essentia AGPL v3, aubio GPL v3) that are incompatible with closed-source App Store distribution and conflict with the Mossgrove Lore's permissive-license requirement (MIT, BSD, Apache 2.0, CC0, CC-BY only). There is no Swift-native, permissively-licensed, App Store-friendly MIR library. MCC fills that gap. Algorithms used in MCC are ported from academic literature (which is not copyrightable) and re-implemented as fresh Swift code owned by Mossgrove. Apple's vDSP / Accelerate framework provides the optimized math infrastructure. Apple's Speech framework provides on-device transcription. CoreML provides the runtime for any future ML models. The combination is unique to MCC and represents real strategic value.

## Philosophy

MusicCraftCore is built on the principle that music understanding is a craft unto itself, and that the algorithms and data structures powering that understanding should be:

1. **Portable and reusable** — extracted from production experience, made generic enough for any Mossgrove music app to depend on without reimplementation.
2. **Observable and testable** — every algorithm is tested in isolation; consumption is validated through integration tests in dependent apps.
3. **Honest about what it knows and doesn't know** — algorithms return confidence scores and degrade gracefully when input quality is poor. No false certainty.
4. **Minimal and focused** — each subsystem solves one problem well. No monolithic pipelines that can't be composed.
5. **Private-first** — all processing is on-device. MCC itself ships no network code and carries no telemetry.

The library serves the musician and the app builder equally. A musician using Cantus benefits from robust chord detection. A developer building a music app benefits from not having to reimplement pitch detection or key inference. Both are served by honest, tested algorithms.

## Consumer Apps

**Cantus** (primary, adopted 0.0.5) — Real-time pitch and chord detection for the guitar. Uses PitchDetector, ChromaExtractor, and ChordDetection subsystems. Wraps MCC's generic ChordDetector with CantusChordDetector for guitar-specific post-processing.

**Guitar Atlas** (secondary) — Chord reference and voicing library. Uses MusicTheory subsystem for chord spelling, interval calculation, and voicing generation.

**Sanctuary** (pending) — Tonal analysis and meditation companion. Needs DSP (pitch, chroma) and AnalysisPipeline for offline audio analysis; does not need Audio subsystem (uses AVFoundation directly per 2026-04-22 decision).

**Future apps** (Vocal App, Ear Training, and others) — will consume appropriate subsystems as they ship.

## Architectural Boundary: Extraction vs. Interpretation

MCC extracts structured musical descriptors from audio. Consumer apps interpret those descriptors — for meaning, mood, genre, recommendation, narrative, emotion, artist comparison — typically via Foundation Models or app-specific logic. The boundary is intentional: extraction is a measurable, testable engineering problem with deterministic outputs; interpretation requires subjective judgment and cultural context that belongs at the application layer.

Consequence: MCC produces typed Swift values now, and will produce a JSON-shaped AnalysisResult record (planned future capability) that bundles all extracted descriptors in a form Foundation Models can consume directly. The consumer app passes that record to its Foundation Model along with whatever app-specific prompt produces the desired interpretation. MCC stays out of the prompt-engineering and interpretation layer entirely.

## Capability Areas

MCC's scope is organized into MIR task categories. Every item has a status indicating where it sits in MCC's roadmap.

**Status legend:**
- **shipped** — currently in a tagged release
- **planned-for-N** — targeted for a specific upcoming release
- **designed** — design exists but no release scheduled
- **deferred** — accepted scope but not actively designed; lifted when a consumer needs it
- **out-of-scope** — explicitly not MCC's responsibility (consumer-side, Apple-framework-side, or interpretation-layer)

### Tonal analysis

- Chroma extraction (DSP/ChromaExtractor) — shipped (0.0.5)
- ChromaTemplateLibrary protocol — shipped (0.0.5)
- ChordClassifierProvider protocol — shipped (0.0.6)
- Chord detection per-frame and multi-frame (ChordDetection/ChordDetector, IntervalDetector) — shipped (0.0.6)
- Multi-path agreement scoring — shipped (0.0.6)
- Roman numeral analysis (MusicTheory/RomanNumeral) — shipped (0.0.7)
- Key inference from chord progression (ProgressionAnalyzer.inferKey) — shipped (0.0.7)
- Pattern recognition with 15-pattern library (ProgressionAnalyzer.recognizePattern) — shipped (0.0.7)
- Key inference from accumulated pitch classes (MelodyKeyInference equivalent) — planned-for-0.0.8
- Modulation detection across a piece — deferred
- Secondary dominants and full chromatic functional analysis — deferred

### Pitch and monophonic analysis

- YIN F0 detection (DSP/PitchDetector) — shipped (0.0.5)
- Median filter and bypass mode for arpeggio responsiveness — shipped (0.0.5)
- Note event extraction (attack-based, detect-once-hold for monophonic content) — planned-for-0.0.8
- Pitch contour with absolute timing (ContourNote: pitchSemitoneStep, parsonsCode, onsetTime, duration) — planned-for-0.0.8 (frozen 2026-04-23)
- Pitch jump and octave error correction — partial in 0.0.5; refinements planned-for-0.0.8

### Rhythm analysis

- Energy-based onset detection (port of Cantus's current algorithm) — planned-for-0.0.8
- Spectral flux onset detection — designed; deferred (future MCC DSP enhancement)
- Beat tracking via onset strength signal autocorrelation (BeatTracker) — shipped (0.0.9)
- Tempo (BPM) estimation from beats or buffer (TempoEstimator) — shipped (0.0.9)
- Harmonic tempo ratio support (isHarmonic flag for double-tempo, half-tempo) — shipped (0.0.9)
- Downbeat detection — deferred
- Meter / time signature inference — deferred

### Structure analysis

- Section segmentation (verse / chorus / bridge boundaries) — designed; deferred until rhythm + tonal are stable. Likely post-0.1.0.
- Repetition / motif detection — deferred

### Timbral and spectral analysis

- FFT and Hann window primitives (DSP/FFT, DSP/windows) — shipped (0.0.5)
- DSP utilities (DSP/DSPUtilities) — shipped (0.0.5)
- MFCCs (Mel-frequency cepstral coefficients) — designed; deferred. Foundation for vocal feature extraction and instrument classification.
- Spectral centroid, rolloff, flatness — designed; deferred. Pair with MFCCs in a future spectral subsystem release.
- Voice activity detection (VAD) — out-of-scope. Apple's SpeechDetector (iOS 26) covers this consumer-side.

### Voice and vocal analysis

- Lyric extraction via Apple Speech framework wrapper (LyricsExtractor) — shipped (0.0.9). Wraps SFSpeechRecognizer (iOS 17+) with forward-compatible path to SpeechAnalyzer (iOS 26+) for per-token confidence in future releases. Produces timestamped word/phrase tokens (TranscribedToken) that align to MCC's chord/melody timeline.
- Vocal range and tessitura — designed; deferred. Computed from F0 distribution.
- Pitch stability over sustained notes — designed; deferred. Standard deviation of F0 within held notes.
- Vibrato analysis: rate, extent, regularity — designed; deferred. Computed from F0 over time via autocorrelation or FFT of the F0 curve.
- Voice type classification: tenor / baritone / bass / soprano / mezzo / alto — designed; deferred. Threshold-based initial implementation using vocal range, tessitura, and FHE (Frequency of Half Energy from spectral envelope; sopranos ~3092 Hz, tenors ~2705 Hz, baritones ~2454 Hz, basses ~2384 Hz per published 2022 thresholds). CoreML refinement later if accuracy warrants.
- Vocal timbre features: spectral brightness, breathiness (spectral flatness), warmth — deferred. Depend on MFCC infrastructure.
- Onset density and phrase length distribution — deferred. Useful proxies for breath control and vocal articulation.

### Music theory primitives

- Note, NoteName, MusicalKey, KeyMode — shipped
- Chord, ChordQuality, SpelledNote — shipped
- DiatonicChordGenerator, Transposer — shipped
- RomanNumeral, SongReference — shipped (0.0.7)
- ProgressionPattern, RecognizedPattern, ProgressionAnalyzer — shipped (0.0.7)
- Tuning value type with preset library (Standard, Drop D, DADGAD, etc.) — deferred. Lifted when a non-Cantus consumer needs guitar-aware fretboard logic.
- TunerStringMatcher (nearest-string + cents-offset given a Tuning) — deferred. Lifts with Tuning.

### Higher-order analysis output

- AnalysisResult JSON-shaped record bundling all extracted descriptors for Foundation Model consumption — designed; deferred. Probable 0.0.9 or 0.1.0 capability. The architectural boundary surface — the canonical input format for consumer-side Foundation Model interpretation.

### Explicitly out of scope (interpretation layer, consumer-side responsibility)

- Mood and emotion classification of musical content
- Genre classification
- Subjective vocal quality descriptors (warmth, soul, brightness as adjectives rather than measurements)
- Artist or stylistic comparison ("sounds like X")
- Lyrical sentiment, narrative arc, thematic analysis
- Music recommendation
- Audio file I/O (AVAudioFile, format conversion, sample rate adaptation) — consumer-side
- AVAudioSession lifecycle and microphone permissions — consumer-side
- Real-time audio capture and engine setup — consumer-side
- CoreML model bundling and ChordClassifier.mlmodel itself — consumer-side
- Speech transcription model management beyond the LyricsExtractor wrapper surface — Apple-framework-side
- Live detection state machine (accumulator, stability window, hold timer, mode stickiness) — consumer-side; UX-driven heuristics that don't generalize across apps
- Audio playback, MIDI mapping, SoundFont rendering — consumer-side

## Subsystems

All subsystems ship as part of a single Swift Package. Consumers import `MusicCraftCore` and access subsystems by type. **Subsystems describe what currently exists in code; see Capability Areas (above) for the complete roadmap and status of all MCC scope including deferred and designed-but-unimplemented work.**

### MusicTheory (0.0.2–0.0.3)

Value types: `Note`, `NoteName`, `Chord`, `ChordQuality`, `MusicalKey`, `KeyMode`, `Scale`, `ScaleMode`, `Interval`, `IntervalQuality`.

Utilities: Note frequency/MIDI conversion, diatonic spelling (LetterName, Accidental, SpelledNote), chord parsing (`Chord.init?(parsing:)`), Roman numeral spelling (`RomanNumeral` with typed Degree/Accidental/Quality), transposition.

Data: `music_theory.json` with circle of fifths, interval formulas, chord formulas, key detection heuristics.

**Status:** Stable. No breaking changes expected. Used by all downstream subsystems.

### DSP (0.0.4–0.0.5)

**PitchDetector** — YIN algorithm with Accelerate/vDSP optimization, confidence-weighted median filter, octave jump exemption, pitch jump detection.

**ChromaExtractor** — FFT-based chroma extraction with 1/octave weighting, noise baseline calibration, spectral floor subtraction.

**CanonicalChromaLibrary** — 120 theoretical chord chroma templates (12 roots × 10 qualities: major, minor, 7, maj7, m7, dim, aug, sus2, sus4, m(maj7)). Conforms to ChromaTemplateLibrary protocol.

**ChromaTemplateLibrary protocol** — Injection point for custom template libraries. Consumer apps can provide recording-derived or tuning-specific templates.

**DSPUtilities** — Window functions (Hann, Blackman), FFT wrapper, helpers for log2 ceiling and window application.

**Status:** Public and stable (0.0.5). All DSP types are public and consumable from external packages. No regressions in dependent apps.

### ChordDetection (0.0.6–0.0.6.1)

**ChordDetector** — Multi-path chord recognition from chroma vectors using template library matching with multi-path agreement scoring. Tuning knobs: silence calibration, spectral floor, energy gate, confidence fallback, agreement boost factors.

**IntervalDetector** — Interval-based chord detection extracting root and quality from peak-based chroma analysis. Root finding via harmonic series analysis; quality detection via interval presence scoring.

**ChordClassifierProvider protocol** — Injection point for ML-based or recording-derived classifiers (complementary to template-matching paths).

**Status:** Public (0.0.6.1). Public initializers added; calibration state audit pending (known gap from Cantus adoption attempt 2026-04-22).

### ProgressionAnalyzer (0.0.7)

**RomanNumeral** — Typed value type with nested Degree (1-7), Accidental, Quality enums. Supports diatonic and borrowed chord spelling (♭II, ♭III, ♭VI, ♭VII, ♯IV). displayString property produces canonical forms (I, i, ♭VII, iiø7, etc.).

**SongReference** — Value type for citing song examples in pattern libraries. Title, artist, detail fields.

**ProgressionPattern** — Well-known chord progressions with numerals, description, and song examples. Static library of 15 patterns.

**RecognizedPattern** — Recognition result: pattern, match type (exact/similar), pass-through accessors for pattern metadata.

**ProgressionAnalyzer** — Stateless public enum with `inferKey(from:)` and `recognizePattern(progression:in:)` static methods.
- **KeyInference:** 24-key diatonic-fit scoring with 6 configurable heuristic weights (first-chord bias, quality alignment, tonic frequency, V→I cadence, IV→I cadence, minor bVII→i).
- **PatternRecognition:** Exact and fuzzy matching (≥3 matches, ≥50% match rate, ±1 length tolerance) on (degree, accidental) pairs.

**Status:** Shipped 0.0.7 (2026-04-24). 143 tests passing. No warnings.

### AnalysisPipeline (pending 0.0.8)

**AudioExtractor** — Stateless offline fragment analysis returning chord progression, key, tempo, and pitch contour from an audio file URL. Orchestrator subsystem combining DSP, ChordDetection, and ProgressionAnalyzer.

**Contour API** — Per-note pitch tracking with onset time (absolute seconds), duration, Parsons code, and signed-semitone steps. Consumers derive IOI ratios or use absolute timings for display/sync.

**Status:** Design phase. Uses diagnosis-plan-execute pattern (design spec → peer review → phased implementation with intermediate ergonomics test).

### Audio (deferred from 0.0.9)

Engine setup, adaptive noise gate, audio file reading.

**Status:** Deferred. Sanctuary confirmed it uses AVFoundation directly (2026-04-22). May resurrect in later extraction if consumer apps need it.

## API Design Decisions

1. **Typed values over strings** — RomanNumeral, SongReference, ProgressionPattern use typed enums and value types, not string-based representations. This catches errors at compile time and enables Equatable, Hashable, Sendable conformance.

2. **Explicit public initializers** — All public types include explicit `public init(...)` to ensure compiler-synthesized memberwise initializers are promoted to public. Regression anchor: PublicAPITests.swift validates all public types are constructible from external modules.

3. **Equatable, Hashable, Sendable by default** — All public types conform to all three protocols. This enables use in collections, dictionaries, actor-isolated contexts, and Swift Concurrency. No exceptions.

4. **Chord-only API** — High-level APIs accept [Chord] not [Note] or raw audio. Raw audio flows through DSP subsystem; chord-level reasoning is separated from note-level signal processing. This creates clean composition boundaries.

5. **Internal weights and heuristics** — ProgressionAnalyzer's key inference uses fixed heuristic weights (first-chord +3.0, etc.). User-configurable weights deferred until a consumer requests them. Internal constants avoid complexity creep in the API.

6. **Static pattern library** — 15-pattern progression library shipped as a static internal array. User-contributed patterns and JSON-based libraries deferred. The 15-pattern subset covers the most common progressions; extensibility is a future feature.

7. **Codable on-demand** — None of MCC's types conform to Codable. This keeps the API surface minimal and avoids coupling to any particular serialization format. Consumers that need JSON serialization implement their own conformance wrappers.

8. **ChromaTemplateLibrary protocol** — The injection point for custom template libraries. This separates the algorithm (ChordDetector, ChromaExtractor) from the data (template source). Default implementation is CanonicalChromaLibrary; consumers provide their own when they have recording-derived training data.

## Versioning Posture

**0.0.x during extraction** — Semantic versioning: 0.0.7 = fourth subsystem shipped (ProgressionAnalyzer). Each release extracts one feature area from Cantus, ships with full test coverage, and is validated in consumer app adoption.

**0.1.0 when extraction complete** — All planned subsystems (MusicTheory, DSP, ChordDetection, ProgressionAnalyzer, AnalysisPipeline, and optionally Audio) shipped and adopted by at least one consumer app.

**1.0.0 when stable for third-party** — MCC is adopted by external developers outside the Mossgrove studio and remains stable across multiple release cycles with no breaking changes.

**Compatibility policy:**
- Minor versions (0.0.x) are not guaranteed to be source-compatible. Breaking changes are acceptable during extraction.
- Public API changes are documented in CHANGELOG.md with migration guidance.
- Once 0.1.0 ships, all 0.1.x versions are source-compatible. Breaking changes require a major version bump.

## Open Questions

1. **Merge strategy for release/0.0.7 to main.** Currently main is ahead of release/0.0.7 (cross-project-log updates). Decision: merge release/0.0.7 to main, or tag 0.0.7 on current main and create release branch from tag? Implications for CI/CD and version numbering.

2. **Typealias bridge patterns for lifted Cantus types.** When Cantus wraps MCC types (e.g., `typealias Note = MusicCraftCore.Note`), should MCC provide companion typealiases in CLAUDE.md for clarity? Example: MCC's CanonicalChromaLibrary might be exposed in Cantus as `typealias ChromaLibrary = MCC.CanonicalChromaLibrary` for brevity in Cantus source.

3. **Sendable audit for legacy types.** Some MusicTheory types (Chord, ChordQuality, others) may not have explicit Sendable conformance. Audit and backfill needed to ensure all public types are Sendable-safe. PublicAPITests should verify all public types pass Sendable compile checks.

4. **Calibration state parity** — ChordDetection's calibration state differs from Cantus's pre-0.0.6 local ChordDetector. Open question for Cantus re-adoption after 0.0.7 ships. See decisions/0002-chorddetection-calibration.md (pending).

5. **Whether to wrap Apple's Speech framework (LyricsExtractor)** at the SFSpeechRecognizer or SpeechAnalyzer level — SFSpeechRecognizer is iOS 17+ baseline; SpeechAnalyzer is iOS 26+ and more capable. Resolved when LyricsExtractor is designed (0.0.9 or later).

6. **AnalysisResult shape** — Whether AnalysisResult is a single bundled record or a composable set of result types (one per task category). Resolved when AnalysisResult is designed (0.0.9 or 0.1.0).

## Relationship to Other Mossgrove Docs

- **MOSSGROVE-LORE.md** — Portfolio-wide philosophy and design principles. MCC embodies "Privacy First," "Atomic" (focused), "Fully Local," and "Simplicity" principles.
- **Cantus TECHNICAL-ARCHITECTURE.md** — Cantus should reference MCC's subsystems as shared dependencies, not reimplementations. CantusChordDetector wrapping MCC.ChordDetector is the canonical integration pattern.
- **Guitar Atlas and Sanctuary CODEXes** — Will define how they consume MusicTheory and DSP subsystems respectively.
- **CLAUDE.md in this repo** — Operational manual for Claude Code sessions. Contains decision classification (green/yellow/red), file locations, test conventions, and session continuity patterns.
- **Workspace coordination** — `/Users/chris/Documents/Code/mossgroves-claude-workspace/mcc.md` tracks consumer adoption status, open blockers, and interproject dependencies.

## Known Limitations and Deferred Work

1. **Pattern library extensibility** — Currently static, internal array of 15 patterns. User-contributed and JSON-based libraries deferred.
2. **Key inference weights** — Currently internal constants. Configurable weights deferred until a consumer requests them.
3. **Calibration state drift** — ChordDetection calibration differs from Cantus's legacy implementation. Audit and remediation pending after 0.0.7 ships.
4. **Transposer enharmonic preference** — Uses fixed sharp/flat spelling (C♯, F♯, etc.). User-preference enharmonic rendering deferred.
5. **Audio subsystem** — Planned for 0.0.9 but deferred indefinitely. Sanctuary uses AVFoundation directly; no confirmed consumer need for on-device Audio subsystem yet.

---

**Last Updated:** 2026-04-26 — MCC 0.0.9 shipped; Voice subsystem (LyricsExtractor) and Rhythm expansion (BeatTracker, TempoEstimator) complete. Capability Areas updated: Voice (LyricsExtractor shipped), Rhythm (beat/tempo shipped). Real-audio fixtures bundled with deferred 0.0.8 work in 0.0.9.1 patch. Next: consumer adoption (Sanctuary Phase D, Cantus rhythm UI), 0.0.1.0 or 0.1.0 planning.
