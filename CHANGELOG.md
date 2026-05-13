# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.11] - 2026-05-12

### Changed
- **`TempoEstimator` buffer path rewritten with spectral-flux onset detection.** Replaces the RMS-energy-based onset signal that produced 0% accuracy with systematic 1/3-tempo error on real guitar audio (Phase 3.2 / 3.3 GuitarSet measurements). The new algorithm uses Dixon 2006 half-wave-rectified spectral flux with adaptive median thresholding, peak picking with a 50ms minimum gap, and a 1-BPM-resolution tempo histogram with internal 2x/0.5x octave-candidate handling.
- **`TempoEstimator.estimateTempo(beats:)` harmonic-candidate ranking fixed.** Previously `harmonicConfidence = regularity * (1.0 / ratio)`, which made 0.5x candidates outrank the base. Replaced with a fixed `regularity * 0.5` octave-error penalty so the base IBI-derived BPM ranks first on regular beat streams. `testGuitarSetTempoAccuracy` moved from 0% within ±10% to 100% within ±5% on the 5-fixture GuitarSet subset; removed from the pre-push known-failing allowlist.
- **`TempoEstimator.Configuration` defaults shifted.** `onsetWindowSize` 2048 → 1024, `onsetHopSize` 1024 → 512 to match the spectral-flux detector's per-frame granularity. Observable to callers passing stored Configuration values; callers using `Configuration()` see no change beyond the underlying algorithm shift. `harmonicRatios` is retained but no longer consulted on the buffer path (the new algorithm generates 2x/0.5x candidates internally).
- **`BeatTracker.detectBeats(buffer:sampleRate:)` rewired** to call `SpectralFluxOnsetDetector` for the onset signal. Its `Configuration` defaults shift identically (1024/512); the autocorrelation step and minAutocorrPeak/inertia fields are no longer consulted (retained for backward compatibility).
- **`TempoEstimate.confidence` doc-comment updated.** Buffer path: fraction of histogram evidence at this BPM. Beats path: inter-beat-interval regularity (1 − std/mean). Consumers should gate display on `confidence ≥ 0.3` to suppress unreliable estimates on low-rhythm material (e.g., monophonic vocals).

### Added
- Internal `SpectralFluxOnsetDetector` (`Sources/MusicCraftCore/DSP/SpectralFluxOnsetDetector.swift`): pure function returning onset times via STFT + spectral flux + adaptive thresholding.
- Internal `TempoHistogram` (`Sources/MusicCraftCore/DSP/TempoHistogram.swift`): pure function returning ranked BPM peaks from a list of onset times. Primary IOI-derived candidate weighted 1.0; 2x/0.5x octave variants weighted 0.5 to break ties in favor of the unambiguous reading.
- `SpectralFluxTempoTests`: 8 new tests covering the regression fixture (120 BPM click track, formerly returning ~40 BPM in the 1/3-bug), histogram correctness on synthetic regular onsets, low-rhythm-content confidence behavior, and detector edge cases (empty, silence).
- `GuitarSetTempoBufferTests.testBufferDerivedTempoConfidenceContract`: real-audio assertion that the algorithm never produces a high-confidence wrong tempo on percussive guitar. On the 5-fixture GuitarSet subset, 1/5 fixtures returns an accurate estimate; the remaining 4/5 return low-confidence estimates (0.05–0.09) that the consumer display gate (0.3) correctly suppresses. This is the load-bearing contract for the Sanctuary consumer use case — pre-0.0.11 the algorithm produced high-confidence wrong tempo with no display-gate signal.

### Public API
- No breaking changes. `TempoEstimator.estimateTempo(beats:buffer:sampleRate:configuration:)`, the `Configuration` struct shape, `TempoEstimate` shape, and `BeatTracker.detectBeats(buffer:sampleRate:configuration:)` are signature-identical. Behavior shifts and Configuration default shifts are documented above.

### Honest measurement notes
- Buffer-derived accuracy on real guitar audio: 1/5 (20%) within ±10% on the 5-fixture GuitarSet subset, below the 40% target stated in `specs/0.0.11-tempo-spectral-flux.md`. The 4 inaccurate cases return confidence 0.05–0.09 — below the 0.3 display gate — so the consumer correctly suppresses display. This is the spec's "experimentation mode; honest measurement matters more than hitting an aspirational number" outcome.
- JAMS-fed accuracy: 100% within ±5% on the same 5-fixture subset after the harmonic-confidence fix.

See `specs/0.0.11-tempo-spectral-flux.md` for full algorithm and rationale.

## [0.0.10.1] - 2026-05-12

### Fixed
- **LyricsExtractor multi-hypothesis flattening:** `transcribe(...)` previously included every alternative hypothesis from `SFSpeechRecognitionResult.transcriptions` via `flatMap`, producing 3x-duplicated transcripts on songs with multiple plausible interpretations (Sanctuary 2026-05-12 device test, 32s vocal capture). Fix: take only `result.transcriptions.first?.segments`. Single-hypothesis return is the correct semantic for the current consumer surface; alternatives can be exposed via a separate entry point in a future release if needed.
- **LyricsExtractor long-buffer truncation:** One-shot `append+endAudio` on a single full-buffer `AVAudioPCMBuffer` truncated clips longer than ~30s (Sanctuary earlier device test, 56s capture transcribed only ~25s). Fix: slice the input buffer into 1-second chunks and `append` each as a separate `AVAudioPCMBuffer` before calling `endAudio`. Keeps the recognizer's stream engaged across the full duration.

### Public API
- No changes. `LyricsExtractor.transcribe(...)` signature, `Configuration` struct, `SpeechFrameworkError` cases, and `TranscribedToken` shape are identical to 0.0.10.

### Tests
- `testSingleHypothesisShape` asserts monotonic onset times on the longest available TTS fixture (regression for the `flatMap` bug).
- `testFullDurationCoverage` concatenates the longest TTS fixture to build a ≥30s buffer and asserts the last token ends within 5s of the buffer end (regression for the truncation bug).
- Both tests skip on macOS / when SFSpeechRecognizer is unavailable, matching the existing `testLyricsExtractorAccuracy` on-device guard.

See `specs/0.0.10.1-lyrics-extractor-fix.md` for full diagnosis and design rationale.

## [0.0.10] - 2026-05-08

### Added
- **Instruments/Guitar subsystem (new):** Voicing library, capo calculator, and voicing scoring for chord accompaniment suggestions.
  - GuitarTuning: 6 standard tunings catalog (Standard, Drop D, Open D, Open G, DADGAD, CGDGBD) with semitone intervals and reference frequencies.
  - VoicingPosition: Fretboard shape data (frets, fingers, barres, baseFret, requiresCapo) with Codable legacy field mapping (capo → requiresCapo).
  - GuitarVoicing: Position + chord + tuning metadata with computed displayName.
  - VoicingLibrary: Chord → ranked voicings lookup. Standard tuning only in 0.0.10; per-tuning data deferred to 0.0.11.
  - CapoCalculator: Target key → capo position suggestions with diatonic-chord-richness scoring. Mode-preserved (major → major, minor → minor).
  - VoicingScore: Composable voicing scoring with fingeringDifficulty, openness, positionScore, spanScore, and weighted totalScore. Default criteria: 0.4 difficulty, 0.3 openness, 0.2 position, 0.1 span (tuned for singer-songwriter use case).
  - guitar_voicings.json: Curated resource (72 chord-name keys × 2–3 voicings) ported from legacy Cantus with rank 1 (open), rank 2 (barre), rank 3 (alternate for easy keys) selection.
  - Test coverage: GuitarTuningTests, VoicingPositionTests, GuitarVoicingTests, VoicingLibraryTests, CapoCalculatorTests, VoicingScoreTests. All passing.
  - Enables Sanctuary slice 9.3 (vocal harmony suggestions): sung melody → inferred key → diatonic chord candidates → tappable voicings with capo positions.

### Known Limitations (0.0.10)
- Diminished and augmented voicings not bundled (diatonic gaps for vii° major / ii° minor).
- Non-standard tunings return empty from VoicingLibrary (per-tuning data deferred to 0.0.11).
- Cross-mode capo mapping (relative major↔minor) deferred to 0.0.11.
- Chord substitution suggestions not implemented.
- Left-handed mirroring not implemented.

### Tier 1 Discipline
- New subsystem with multiple public types and new architecture pattern (Instruments/Guitar/).
- Released after Chris review of design spec, implementation, and post-Phase-B drift acknowledgments (rank-3 voicing scope expansion, filtered-test masquerade fix-forward in commit 9a2b61c).
- Phase reports use canonical template; Capability-Context Fit audit confirmed fit for Sanctuary slice 9.3 consumption.

### Added
- **Phase 3 GuitarSet integration test infrastructure:** Real-audio testing on polyphonic multi-chord guitar excerpts with JAMS annotations.
  - JAMSParser: minimal Swift JSON parser for JAMS (chord_harte, beat, key_mode namespaces only). Harte notation translator (e.g., `A:min` → `Am`). Scope-limited to GuitarSet files; no external dependencies.
  - GuitarSetFixture: 20 acoustic guitar excerpts from Zenodo dataset (CC-BY 4.0, NYU MARL + Queen Mary). Fixture loading with JAMS parsing and lazy WAV audio decoding.
  - GuitarSetDownloaderTests (gated `MCC_DOWNLOAD_GUITARSET=1`): downloads annotation.zip and audio_hex-pickup_debleeded.zip from Zenodo record 3371780 via Zenodo API. Extracts 20 target files per genre (BossaNova, Funk, Rock, Singer-Songwriter). Writes MANIFEST.txt with SHA256 verification and CC-BY attribution. Idempotent (skips existing files with matching hashes).
  - AudioAnalysisMetrics extensions: ProgressionMetrics (CSR at majMin vocabulary, median timing deviation, no-detection fraction), TempoMetricsExtended (tempoError, within5pct/10pct/20pct tolerances, halftime/doubletime error detection), KeyMetrics (exactMatch, relativeKeyMatch, rootMatch, ground truth vs detected comparison).
  - GuitarSetProgressionTests, GuitarSetTempoTests, GuitarSetKeyInferenceTests: test suites for chord progressions (CSR frame-by-frame at 10ms), tempo estimation (from beat times), and key inference (chord-rich material only). Thresholds calibrated to literature baselines with explicit calibration-down rules.
  - Security evaluation: `docs/security/phase-3-guitarset-evaluation.md` documents threat model (no code injection, safe unzip usage, JSONDecoder-only parsing).
  - **Scope limitation:** Phase 3 measures key inference on chord-rich comping material only. MelodyKeyInference pitch-class fallback path NOT exercised. Do not claim general key-inference accuracy from Phase 3 results.
  - Documentation: Fixtures/real-audio/guitarset/README.md with JAMS format spec, Harte notation guide, Zenodo citation, scope limitation.

### Added
- **Real-audio fixture integration (Phase 2.5, corrective):** GADA + TaylorNylon guitar recordings from legacy Cantus, 32+109 WAV files with ground-truth JSON sidecars. Replaces Phase 2's ineffective SoundFont synthetic approach.
  - Fixture sources: 32 GADA files (3 guitar models, 12 common chords, fingerstyle) + 109 TaylorNylon files (7 chord types, nylon classical timbre).
  - JSON sidecars encode single-chord ground truth (chord name, confidence=1.0) using GroundTruthCodable envelope.
  - RealAudioChordTests: per-file accuracy comparison (root + exact chord) against Phase 2.5 measured baseline (GADA: 40.6% root / 68.8% exact; TaylorNylon: 31.2% root / 49.5% exact). Thresholds reflect AudioExtractor's real performance on this subset, calibrated to detect regression, not match legacy Cantus Stage 2 (which achieved 99.7% on full 3449-sample dataset).
  - Package.swift: resources declaration copies AudioAnalysis/Fixtures to test bundle.
  - SidecarGenerationTests (gated MCC_GENERATE_SIDECARS=1): regenerates JSON sidecars from WAV files if needed.
  - Confusions analysis: GADA harmonic confusion (Em/E→B patterns), TaylorNylon nylon timbre overlap (Fm→G♯, F→A patterns).
  - Documentation: Fixtures/real-audio/README.md with source provenance, measurement methodology, confusion categorization, maintenance guidance.

- **Audio analysis testing infrastructure (Phase 1):** Synthetic fixture baseline + test harness for chord, tempo, and note detection validation.
  - AudioFixtureLoader: lazy fixture loading with support for synthetic audio generation (all-major-triads, all-minor-triads, common-sevenths, steady-tempo metronome, C major scale) and optional ground-truth annotations.
  - SyntheticGenerator: static helper methods for creating test audio (generateSineWave, generateChordBuffer, generateMetronomeClick, etc.) with envelope modeling (attack, sustain, release).
  - GroundTruth: enum annotation types for chord progressions, tempo, melody notes, and lyrics with timing and confidence metadata.
  - AudioAnalysisMetrics: mir_eval-inspired chord comparison (rootAccuracy, qualityAccuracy, exactAccuracy, timingDeviation, falsePositives, falseNegatives) using majMin chord reduction and timing tolerance windows. Also includes tempo and note comparison metrics.
  - SyntheticChordTests, SyntheticTempoTests, SyntheticNoteTests: structural validation tests for extraction pipeline (correctness validation deferred to real-audio Phase 2 with GADA dataset).
  - All tests pass (290/290 suite). Documentation: docs/AUDIO_TESTING_STRATEGY.md with 7-section specification of test fixtures, metrics, harness architecture, and 5-phase implementation plan.

## [0.0.9] - 2026-04-26

### Added
- **Voice subsystem (new):** LyricsExtractor for on-device lyric transcription using Apple's Speech framework.
  - LyricsExtractor: async transcribe method wrapping SFSpeechRecognizer (iOS 17+ baseline) with forward-compatible path to SpeechAnalyzer (iOS 26+) via feature detection in future releases.
  - TranscribedToken: timestamped word-level tokens with text, onsetTime, duration, optional confidence (iOS 26+ only).
  - SpeechFrameworkError: wrapped error handling for framework unavailability, recognition failures, locale mismatch, and permission denial.
  - Enables lyric-based search and analysis in consumer apps (e.g., Sanctuary hum-to-search with lyric matching).

- **DSP subsystem expansion:** BeatTracker and TempoEstimator for rhythm analysis.
  - BeatTracker: beat detection via onset strength signal autocorrelation (RMS-based energy per frame, Accelerate-optimized). Configuration tuning: window/hop sizes, beat period range (20–200 BPM), autocorrelation threshold, inertia parameter for beat stability.
  - TempoEstimator: tempo estimation from pre-detected beats or directly from audio buffer. Returns ranked candidate tempos with confidence scores and harmonic classification (captures tempo ambiguities from syncopation, rubato, triplets). Reuses BeatTracker for buffer path.
  - TempoEstimate: public struct with bpm, confidence, isHarmonic flag for client-side tempo disambiguation.
  - Both subsystems fully independent (no coupling between BeatTracker and TempoEstimator; coordinated onset computation deferred to 0.0.10+).

### Known Limitations
- **Real-audio fixtures deferred:** 0.0.9 ships with synthetic fixture tests only (structural validation, no algorithm accuracy on real audio). Real-audio ground-truth evaluation (beat accuracy, tempo estimation on live recordings) bundled with deferred 0.0.8 real-audio fixtures in 0.0.9.1 patch or 0.1.0 release.
- **LyricsExtractor per-token confidence:** iOS 17 path (SFSpeechRecognizer) does not expose per-token confidence; confidence field always nil. SpeechAnalyzer (iOS 26+) with per-token confidence deferred to 0.0.10 as iOS 26 adoption broadens (currently ~60–70% market reach).
- **Beat inertia parameter:** Exposed in BeatTracker.Configuration but not actively used in beat induction algorithm (baseline inertia = 0.5). Sophisticated Viterbi/HMM-based tempo tracking deferred to post-0.1.0.
- **Tempo range:** 300–3000ms (20–200 BPM) covers typical pop/rock. Very slow music (<20 BPM, e.g., classical adagio) may be detected at double/triple/quarter tempo. Configurable via minBeatPeriodMs/maxBeatPeriodMs.
- **Beat detection algorithm:** Autocorrelation-based; tempogram + Viterbi and ML-based refinement deferred to future releases.

### Consumer Adoption Recommended
- **Sanctuary:** Phase D search integration — lyric matching on LyricsExtractor tokens, rhythm-aware analysis using BeatTracker/TempoEstimator.
- **Cantus:** Rhythm UI features — beat visualization from BeatTracker, tempo awareness from TempoEstimator.
- **Guitar Atlas:** Rhythm transcription support (future work pending real-audio validation in 0.0.9.1).

## [0.0.8] - 2026-04-25

### Added
- AudioExtractor: offline audio analysis pipeline composing all MCC subsystems (DSP primitives, music theory types, chord detection, pitch detection, key inference) into a unified Result struct with chord segments, inferred key, melodic contour, detected notes, and buffer duration.
- AudioExtractor.Configuration: tuning parameters for onset detection (minGapMs, energyMultiplier, energyFloor), chroma analysis (windowSize, hopSize), early-frame windowing (attackSkip, windowSize), extraction confidence thresholds, and silence threshold for noise calibration.
- AudioExtractor.Result: public struct bundling chordSegments, inferred MusicalKey, ContourNote contour, DetectedNote array, and duration.
- AudioExtractor.ChordSegment: public struct with UUID id, start/end times, detected Chord, confidence score, and DetectionMethod enum (classifier/interval/agreement).
- ContourNote and ParsonsCode: melodic pitch trajectory with direction codes (up "*", down "d", repeat "r") per MIR literature. First note convention: pitchSemitoneStep=0, parsonsCode=.repeat_ for no-predecessor case.
- DetectedNote: raw monophonic note event with MIDI note, absolute timing, duration, confidence, and computed pitchClass property.
- MelodyKeyInference: key inference via diatonic-fit scoring on 24 keys (12 roots × 2 modes), with tie-breaking by tonic frequency count and minor mode preference. Returns ordered KeyCandidate array with key, score, tonicFrequency.
- OnsetDetector: energy-based note onset detection using RMS energy with running average threshold (multiplier × previous_average). Configurable gap enforcement to prevent sub-threshold repeats.
- NoiseCalibrator: silence frame detection via RMS threshold; averaged chroma extraction from silence windows for noise baseline subtraction. Contamination limit prevents non-silence baselines.
- NoiseBaseline: public struct with chroma vector and frameCount for noise-aware analysis.
- Sendable conformance on Chord and ChordQuality (additive; required for AudioExtractor.ChordSegment Sendable conformance).
- Hashable conformance on Chord (additive; non-breaking).

### Changed
- Chord struct now conforms to Hashable and Sendable in addition to Equatable and Identifiable. Non-breaking.
- ChordQuality enum now conforms to Sendable. Non-breaking.

### Known Limitations
- AudioExtractor pipeline tests in 0.0.8 are structural-only. Synthetic test fixtures (sine waves with smooth envelopes) cannot drive OnsetDetector's RMS-energy threshold reliably enough to validate end-to-end chord detection and key inference correctness. Real-audio fixture tests with recorded guitar and vocal samples are deferred to a future patch release (likely 0.0.8.1 or 0.0.9). Cantus and Sanctuary consumer adoption will exercise the pipeline against real audio in production use.
- Onset detection is energy-based (RMS with running average); spectral flux upgrade deferred to a future MCC DSP enhancement.
- KeyInference and MelodyKeyInference heuristic weights remain internal constants; configurable weights deferred until a consumer requests them.
- ContourNote pipeline assumes monophonic pitched input; polyphonic vocal/instrumental sources produce sparse or empty contour. Sanctuary will validate Configuration defaults against representative vocal recordings during slice 9 integration.

## [0.0.7] - 2026-04-24

### Added
- RomanNumeral value type with Degree, Accidental, and Quality nested enums. Supports diatonic and borrowed chord spelling (♭II Neapolitan, ♭III, ♭VI, ♭VII, ♯IV). Equatable, Hashable, Sendable.
- SongReference value type for citing song examples in pattern libraries. Equatable, Hashable, Sendable.
- ProgressionPattern and RecognizedPattern types describing well-known chord progressions and recognition results. Equatable, Hashable, Sendable.
- ProgressionAnalyzer stateless enum with `inferKey(from: [Chord]) -> MusicalKey?` and `recognizePattern(progression: [Chord], in: MusicalKey) -> RecognizedPattern?` static methods.
- 15-pattern library covering common pop, folk, jazz, rock, and classical progressions with song examples: Pop Anthem, Sensitive/Emotional, Classic Rock/Folk, Jazz Standard, 50s Doo-wop, Andalusian Cadence, Mixolydian Rock, Natural Minor Folk, Building/Uplifting, Dreamy/Nostalgic, Epic/Cinematic, Jazz Turnaround, Plagal Pop, Canon in D, Phrygian Cadence.
- MusicalKey.romanNumeralTyped(for:) companion to existing string-returning romanNumeral(for:).
- Hashable and Sendable conformance on MusicalKey and KeyMode.

### Changed
- MusicalKey now conforms to Hashable and Sendable in addition to Equatable. Non-breaking.
- NoteName now conforms to Sendable to support MusicalKey Sendable conformance.

### Housekeeping
- CHANGELOG: split 0.0.6.1 into its own heading; restored 0.0.6 entry to ChordDetection content.

### Known Limitations
- Pattern library is a static internal array of 15 entries. User-contributed patterns and JSON-based libraries are deferred to a later release.
- KeyInference heuristic weights are internal constants. Configurable weights deferred until a consumer requests them.

## [0.0.6.1] - 2026-04-22

### Fixed
- Release-engineering gap: ChordDetection types were declared without `public` access on Result and Peak initializers, making them unconsumable by external apps. Explicit public initializers added to `ChordDetector.Result`, `IntervalDetector.Result`, and `IntervalDetector.Peak`. Compiler-synthesized memberwise initializers were not promoted to public when accessed from external modules, blocking consumer apps from constructing Result types for adaptation or testing. Issue surfaced by Cantus's 0.0.6 adoption attempt (2026-04-22).
- PublicAPITests extended with direct Result and Peak construction tests via public initializers. Three new tests serve as regression anchors: `testChordDetectorResultPublicInit`, `testIntervalDetectorPeakPublicInit`, `testIntervalDetectorResultPublicInit`.

## [0.0.6] - 2026-04-22

### Added
- ChordDetection subsystem with multi-path chord recognition.
- ChordDetector: chord recognition from chroma vectors using template library matching with multi-path agreement scoring. Tuning knobs: silence calibration threshold, spectral floor subtraction, energy gate multiplier, confidence fallback threshold, agreement boost factors.
- IntervalDetector: interval-based chord detection extracting root and quality from peak-based chroma analysis. Root finding via harmonic series analysis and pitch-class correlation. Quality detection using interval presence scoring and thresholding.
- ChordClassifierProvider protocol: injection point for ML-based or recording-derived chord classifiers. Complementary to template-matching paths.
- Multi-path agreement scoring: ChordDetector scores agreement between template-matching and interval-detection paths with configurable boost factors (full agreement vs. root-only agreement).
- Template pre-filtering: peak-based pre-filter to reduce candidate templates before exhaustive distance matching.
- Comprehensive chord detection test suite validating template matching, interval detection, agreement scoring, and public API accessibility.

## [0.0.5] - 2026-04-22

### Added
- Public access modifiers on all DSP types: `PitchDetector`, `ChromaExtractor`, `CanonicalChromaLibrary`, window functions (Hann, Blackman), FFT wrapper, `DSPUtilities`, noise baseline configuration.
- `ChromaTemplateLibrary` protocol with `distance(_:to:) -> Double` and `availableChordNames: [String]` requirements. Allows consumer apps to inject recording-derived or app-specific template libraries while keeping MCC's algorithms generic.
- `PublicAPITests.swift` exercising the public surface without `@testable import`. Regression anchor against accidental re-privatization in future releases.

### Changed
- Renamed `ReferenceChromaLibrary` → `CanonicalChromaLibrary`. New name more accurately describes the theoretical template library as distinct from consumer-provided recording-derived libraries. The type now conforms to `ChromaTemplateLibrary` as a public struct rather than an internal enum.
- `ChromaExtractor` (and any other DSP type with template-library dependencies) now accepts a `ChromaTemplateLibrary` parameter with `CanonicalChromaLibrary()` as default. Existing call sites are unchanged.

### Fixed
- 0.0.4 release-engineering gap: DSP types were declared without `public` access, making them unconsumable by external apps. Cantus's 0.0.4 adoption attempt (2026-04-22) surfaced the issue. See decisions/mcc-0.0.4-adoption-audit.md in mossgroves-cantus for the full finding.

## [0.0.4] - 2026-04-22

### Added
- DSP subsystem with pure algorithm implementations (no AudioEngine, CoreML, or UI coupling).
- PitchDetector: YIN algorithm with Accelerate/vDSP optimization, confidence-weighted 3-frame median filter, octave jump exemption (12±0.5 and 24±0.5 semitones), pitch jump detection (>3 semitones flushes filter on high confidence).
- ReferenceChromaLibrary: 120 chord chroma templates (12 roots × 10 qualities: major, minor, 7, maj7, m7, dim, aug, sus2, sus4, m(maj7)), Euclidean distance function for template matching.
- FFT wrapper: vDSP-accelerated real-to-complex FFT with split-complex buffer management.
- Window functions: Hann and Blackman windows via vDSP for spectral analysis (Blackman: ~58 dB sidelobe suppression).
- ChromaExtractor: FFT-based chroma extraction with 1/octave weighting (bass frequencies more prominent), noise baseline calibration with 10-frame averaging and 10% floor protection to prevent weak-but-real signals from being zeroed.
- DSPUtilities: Helper functions for window generation, log2 ceiling, and window application.
- Comprehensive DSP test suite: 14 tests covering YIN on sine tones (A440, E329.63, C261.63), confidence degradation on noise, median filter smoothing, window properties, chroma extraction, and ReferenceChromaLibrary.

## [0.0.3] - 2026-04-21

### Added
- Transposer public API explicitly exposed (was public but inaccessible due to module shadowing).

### Fixed
- Removed placeholder `public enum MusicCraftCore` that shadowed module name and prevented qualified type access (e.g., `MusicCraftCore.Transposer`).

### Changed
- Version constant moved from type member to module-level public constant `musicCraftCoreVersion` to avoid shadowing the module name.

## [0.0.2] - 2026-04-21

### Added
- MusicTheory subsystem with core primitives: NoteName, ChordQuality, Chord, Note, MusicalKey
- Note frequency/MIDI conversion utilities (MusicTheory enum)
- Diatonic spelling and chord generation: LetterName, Accidental, SpelledNote, DiatonicChordGenerator, RelatedKeys
- Chord parsing: Chord.init?(parsing:) for parsing chord name strings (e.g., "Am7", "F♯", "B♭dim")
- Transposition utilities: Transposer enum for Roman numeral transposition
- Music theory reference data: music_theory.json with scales, intervals, chord formulas, circle of fifths, progressions, key detection rules
- TheoryReference struct with load() and shared lazy-loaded instance for bundled JSON data
- Comprehensive test suite for all music theory types

### Known Limitations
- Transposer uses fixed sharp/flat spelling (C♯, F♯, G♯, A♯, D♭, E♭, A♭, B♭); user-preference enharmonic rendering is a future enhancement.

## [0.0.1] - 2026-04-21

### Added
- Swift Package skeleton with Package.swift manifest
- Subsystem directory structure (Audio, DSP, ChordDetection, MusicTheory, AnalysisPipeline, Resources)
- Test target with baseline test
- README with project overview and usage documentation
