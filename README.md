# MusicCraftCore

Mossgrove's on-device music-analysis library: audio in, musical descriptors out, plus a music-theory layer. Consumed as a Swift Package dependency.

## Principle

Privacy-first and security-first. Everything runs on the device. MCC ships no network code and carries no telemetry; the consuming app owns capture, playback and the audio session.

## What it does (0.1.17)

**Transcription.** Spotify's Basic Pitch (a bundled Core ML model, `nmp.mlpackage`) transcribes notes from a buffer or a file. It has been the only note engine since 0.1.0 (2026-06-01), when the hand-rolled YIN / chroma / template chord path was deleted.

**AnalysisPipeline.** `AudioExtractor.extract` returns chord segments, key, tempo, the melodic contour and the full polyphonic note list from one transcription.

**ChordDetection.** Note-native chord naming (`NoteChordIdentifier`) with a Viterbi sequence decode (`ChordSequenceDecoder`) and a bare-dyad guard.

**MusicTheory.** Value types (`Note`, `Chord`, `MusicalKey`, `RomanNumeral`, …), key inference from chords and from melody (Krumhansl profiles), progression pattern recognition, transposition, and the theory JSON.

**Instruments/Guitar.** Voicings from chords-db, capo math, tunings, voicing scoring.

**DSP.** Tempo: spectral-flux onsets, beat tracking, tempo histogram and estimate. (No pitch or chroma DSP remains.)

**Voice.** Sung-lyric transcription: WhisperKit (whisper-small, pinned decode configuration, a decode-time repetition brake and a run guard since 0.1.17) with Apple's Speech framework as the on-device fallback; a vocal-stem side-channel (`VocalIsolator`) for tracing a sung melody.

MCC does not record, play or route audio and owns no `AVAudioSession`.

## Consuming MCC

```swift
// Package.swift
.package(url: "https://github.com/mossgroves/music-craft-core.git", from: "0.1.17")
.product(name: "MusicCraftCore", package: "music-craft-core")
```

Platforms iOS 17 / macOS 14, swift-tools 5.9. WhisperKit 1.1.0 (MIT) comes along as an exact-pinned dependency. A path dependency (`.package(path: "../mossgroves-music-craft-core")`) takes its package identity from the DIRECTORY name, so the product line then reads `package: "mossgroves-music-craft-core"`.

## Status

Version 0.1.17, tagged 2026-09-03. Consumed by Songcatcher (Songwriter's Sanctuary). 523 test declarations; the pre-push hook runs the suite on every push to main against an allowlist of two deliberate GuitarSet failures. Releases go through `scripts/release.sh`, which stops before the tag; the tag and the push are Chris's word. See `CLAUDE.md` for the operating rules and `CHANGELOG.md` for every release.

## Third-party material

Listed in `NOTICE` with licence texts in-bundle: Basic Pitch (Spotify, Apache 2.0, `BASIC_PITCH_LICENSE.txt`), chords-db (MIT, `Resources/chords_db_LICENSE.txt`), WhisperKit (Argmax, MIT). Portfolio rule: MIT / BSD / Apache 2.0 / CC0 / CC-BY only.

## License

To be decided. Placeholder until the Mossgrove portfolio license is set.
