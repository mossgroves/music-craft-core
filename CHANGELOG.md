# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
