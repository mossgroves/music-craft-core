# MusicCraftCore

Shared DSP, music theory data, and audio analysis primitives for the Mossgrove music apps. Consumed as a Swift Package dependency.

## Principle

Privacy-first and security-first. Network and telemetry are allowed where they genuinely serve users and preserve privacy. MCC itself is pure data and logic with no network in v0.x, but the design does not foreclose additions that serve users.

## Subsystems

Audio. Engine setup, adaptive noise gate, audio file reading.

DSP. Public algorithm primitives (FFT, Hann/Blackman windows, YIN pitch detection, chroma extraction, noise baseline) plus a ChromaTemplateLibrary protocol for pluggable chord template matching. Ships CanonicalChromaLibrary as a default implementation using 120 theoretical templates (12 roots × 10 qualities). Consumer apps can provide their own conforming library when they have recording-derived training data.

ChordDetection. Hybrid classifier pipeline with CoreML classifier, interval detector, and classifier-plus-interval agreement.

MusicTheory. Value types (Chord, Key, Scale, Mode, RomanNumeral, etc.), key inference from chromas and from note sequences, progression analysis with pattern detection, chord voicings per tuning, tuning definitions, and data loaders for the music theory JSON files.

AnalysisPipeline. AudioExtractor for offline fragment analysis that returns chord progression, key, tempo, and pitch contour from an audio file URL.

## Consuming MCC

Add to your Package.swift:

```swift
.package(url: "https://github.com/mossgroves/music-craft-core.git", from: "0.0.5")
```

## Status

Version 0.0.5. DSP subsystem now publicly consumable with injectable ChromaTemplateLibrary protocol. Earlier 0.0.4 release shipped the DSP algorithms but declared them internal; 0.0.5 corrects the access modifiers. CanonicalChromaLibrary is the default implementation using 120 theoretical templates (12 roots × 10 qualities). Music theory primitives remain at 0.0.3 state. ChordDetection, AnalysisPipeline, and Audio subsystems remain pending extraction and will land in subsequent releases, with 0.1.0 tagged once the full migration from Cantus completes.

## License

To be decided. Placeholder until Mossgrove portfolio license is set.
