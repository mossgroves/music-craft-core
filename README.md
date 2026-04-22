# MusicCraftCore

Shared DSP, music theory data, and audio analysis primitives for the Mossgrove music apps. Consumed as a Swift Package dependency.

## Principle

Privacy-first and security-first. Network and telemetry are allowed where they genuinely serve users and preserve privacy. MCC itself is pure data and logic with no network in v0.x, but the design does not foreclose additions that serve users.

## Subsystems

Audio. Engine setup, adaptive noise gate, audio file reading.

DSP. Public algorithm primitives (FFT, Hann/Blackman windows, YIN pitch detection, chroma extraction, noise baseline) plus a ChromaTemplateLibrary protocol for pluggable chord template matching. Ships CanonicalChromaLibrary as a default implementation using 120 theoretical templates (12 roots × 10 qualities). Consumer apps can provide their own conforming library when they have recording-derived training data.

ChordDetection. Hybrid classifier pipeline with optional CoreML classifier (via ChordClassifierProvider protocol), interval detector, multi-path agreement scoring, and template pre-filter re-ranking. Gracefully degrades to template + interval matching if classifier unavailable. Consumer apps can inject their own classifier implementation.

MusicTheory. Value types (Chord, Key, Scale, Mode, RomanNumeral, etc.), key inference from chromas and from note sequences, progression analysis with pattern detection, chord voicings per tuning, tuning definitions, and data loaders for the music theory JSON files.

AnalysisPipeline. AudioExtractor for offline fragment analysis that returns chord progression, key, tempo, and pitch contour from an audio file URL.

## Consuming MCC

Add to your Package.swift:

```swift
.package(url: "https://github.com/mossgroves/music-craft-core.git", from: "0.0.6")
```

## Status

Version 0.0.6. ChordDetection subsystem now publicly consumable. Three-stage pipeline: template pre-filter → reference re-ranking → optional CoreML classifier, with deterministic interval detector fallback. ChordClassifierProvider protocol enables dependency injection — consumer apps provide their own classifier (e.g., CoreML model) and default to template + interval matching if unavailable. DSP subsystem (0.0.5) exposes PitchDetector, ChromaExtractor, CanonicalChromaLibrary (120 theoretical templates), and ChromaTemplateLibrary protocol. Music theory primitives at 0.0.3 state. AnalysisPipeline and Audio subsystems pending extraction; 0.1.0 tagged when full Cantus migration completes.

## License

To be decided. Placeholder until Mossgrove portfolio license is set.
