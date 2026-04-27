# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
