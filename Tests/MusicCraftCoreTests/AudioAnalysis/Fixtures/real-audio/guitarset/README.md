# GuitarSet Test Fixtures

Phase 3 real-audio testing infrastructure for MusicCraftCore.

## Overview

20 acoustic guitar excerpts from the GuitarSet dataset with JAMS (JSON Annotation Metadata Schema) annotations covering:
- **Chord progressions** (chord_harte namespace)
- **Beat timing** (beat namespace)
- **Key inference** (key_mode namespace)

## Scope Limitation

Phase 3 measures key inference on **chord-rich comping material only**. AudioExtractor uses chord-based key inference (Krumhansl-Schmuckler) as the primary path when ≥2 distinct chords are detected. **MelodyKeyInference's pitch-class fallback path is NOT exercised** by these test fixtures. Do not claim general key-inference accuracy from Phase 3 test results.

## Contents

- 5 BossaNova clips (tempos 129 BPM, key Eb major)
- 5 Funk clips (tempos 119 BPM, key A major)
- 5 Rock clips (tempos 130 BPM, key A major)
- 5 Singer-Songwriter clips (tempos 68 BPM, key E major)

Each fixture: `{player}_{genre}{details}_comp.wav` + `.jams`

## Attribution

```
GuitarSet: A Dataset for Guitar Chord and Key Identification
Travers, M., Pardo, B., & Humphrey, E. J. (2017)
Citation: Characterizing the diversity of audio representations.
         Machine Learning for Music Discovery Workshop.

Source: Zenodo, record 3371780
https://zenodo.org/records/3371780
License: CC-BY 4.0

Audio courtesy of the New York University Machine Learning for Acoustics Lab (NYU MARL)
and Queen Mary University of London Centre for Digital Music.
```

## Download

Fixtures are committed to git. If missing, regenerate via:

```bash
cd mossgroves-music-craft-core
MCC_DOWNLOAD_GUITARSET=1 swift test --filter GuitarSetDownloaderTests
```

This is a one-time operation; subsequent test runs use committed files.

## Test Suites

- **GuitarSetProgressionTests** — Chord progression accuracy (CSR on 30-second multi-chord clips)
- **GuitarSetTempoTests** — Tempo and beat detection
- **GuitarSetKeyInferenceTests** — Key inference on chord-rich material (scope-limited as noted above)

## Test Data Format

JAMS files use standard namespaces:

```json
{
  "file_metadata": {
    "duration": 30.5
  },
  "annotations": [
    {
      "namespace": "chord_harte",
      "data": [
        { "time": 0.0, "value": { "chord": "C:maj" } },
        { "time": 2.5, "value": { "chord": "A:min" } },
        ...
      ]
    },
    {
      "namespace": "beat",
      "data": [
        { "time": 0.0, "value": 1.0 },
        { "time": 0.5, "value": 2.0 },
        ...
      ]
    },
    {
      "namespace": "key_mode",
      "data": [
        { "time": 0.0, "value": { "root": "C", "mode": "major" } }
      ]
    }
  ]
}
```

Harte chord notation: `Root:Quality` (e.g., `A:min`, `C:maj`, `G:7`, `N` for no-chord).

## References

- Zenodo record: https://zenodo.org/records/3371780
- JAMS format: https://musicinformationretrieval.com/jams.html
- Harte notation: https://en.wikipedia.org/wiki/Harte_chord_notation
