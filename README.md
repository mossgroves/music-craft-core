# MusicCraftCore

Shared DSP, music theory data, and audio analysis primitives for the Mossgrove music apps. Consumed as a Swift Package dependency.

## Principle

Privacy-first and security-first. Network and telemetry are allowed where they genuinely serve users and preserve privacy. MCC itself is pure data and logic with no network in v0.x, but the design does not foreclose additions that serve users.

## Subsystems

Audio. Engine setup, adaptive noise gate, audio file reading.

DSP. FFT-based chroma, YIN pitch, HCDF, tempo estimator, onset detector.

ChordDetection. Hybrid classifier pipeline with CoreML classifier, interval detector, and classifier-plus-interval agreement.

MusicTheory. Value types (Chord, Key, Scale, Mode, RomanNumeral, etc.), key inference from chromas and from note sequences, progression analysis with pattern detection, chord voicings per tuning, tuning definitions, and data loaders for the music theory JSON files.

AnalysisPipeline. AudioExtractor for offline fragment analysis that returns chord progression, key, tempo, and pitch contour from an audio file URL.

## Consuming MCC

Add to your Package.swift:

```swift
.package(url: "https://github.com/mossgroves/music-craft-core.git", from: "0.0.4")
```

## Status

Version 0.0.4. DSP subsystem complete with pure algorithm implementations: PitchDetector (YIN with confidence-weighted 3-frame median filter), ReferenceChromaLibrary (98 chord chroma templates), FFT wrapper with Hann/Blackman windowing, chroma extraction with octave weighting (bass-prominent), and noise baseline calibration with floor protection. MusicTheory subsystem complete with core primitives (NoteName, Chord, ChordQuality, Note, MusicalKey), diatonic spelling (SpelledNote, LetterName, Accidental, DiatonicChordGenerator), transposition utilities (Transposer), and music theory reference data (music_theory.json). ChordDetection (CoreML-based classifier) and AnalysisPipeline (high-level orchestration) remain pending and will land in subsequent 0.0.x releases, with 0.1.0 tagged once the full migration from Cantus completes.

## License

To be decided. Placeholder until Mossgrove portfolio license is set.
