# Real-Audio Chord Test Fixtures

## Overview

Phase 2.5 real-audio fixtures for MusicCraftCore audio analysis testing. 141 WAV files (32 GADA + 109 TaylorNylon) sourced from legacy Cantus, with ground-truth chord labels in JSON sidecars.

## Source Datasets

### GADA: Guitar and Associated Data (32 files, 29MB)

Subset of the full GADA dataset from `mossgroves-cantus/TestData/GADA/`. Selection criteria: 3 guitar models (ArgSG, Gretsch, HBLP) × 12 common open chords (A, Am, B, Bm, C, D, Dm, E, Em, F, G, Gm), single-takes variant.

**File naming:** `{Model}_{Chord}_open_022_ID{X}_{Y}.wav`
- Model: ArgSG (12 files, ID4_1 or ID1_1), Gretsch (12 files, ID1_1 or ID1_2), HBLP (8 files, ID1_1)
- Chord extracted from `parts[1]` of filename split by underscore
- 44.1 kHz, mono, ~3–5 seconds per file

**Why GADA:**
Acoustic guitars with finger picking, sparse voicings (3–4 strings), realistic finger noise and harmonic variation. Exercises AudioExtractor's tuning for fingerstyle electric-acoustic recordings (primary instrument category for Cantus).

### TaylorNylon: Taylor Nylon Acoustic Guitar (109 files, 28MB)

Entire dataset from `mossgroves-cantus/TestData/TaylorNylon/`, 7 chord types with data:
- Am (13 files), C (14), D (13), Dm (9), Em (12), F (13), Fm (16), G (19)
- 44.1 kHz, mono, ~5–8 seconds per file
- Chord label = folder name

**Why TaylorNylon:**
Nylon-string acoustic with more complex sustained overtones and less percussive attack than GADA. Tests AudioExtractor's generalization to classical guitar timbre.

## Ground Truth Sidecars

Each `.wav` has a corresponding `.json` sidecar encoding ground truth:

```json
{
  "type": "singleChord",
  "data": {
    "chord": "Am",
    "confidence": 1.0
  }
}
```

All fixtures are single-chord, confidence=1.0 (human-verified labels from original dataset).

## Measured Accuracy (Phase 2.5)

AudioExtractor baseline on this subset (MCC current build):
- **GADA:** root 40.6% (13/32), exact 68.8% (22/32)
- **TaylorNylon:** root 31.2% (34/109), exact 49.5% (54/109)

Note: These are lower than legacy Cantus Stage 2 (99.7% GADA root / 96.4% exact on 3449-sample dataset), reflecting the harder nature of this subset and architectural differences between implementations. Thresholds calibrated to detect regressions, not to match the older baseline.

## Confusion Patterns

### GADA (8 unique confusions):
- Em→B (2), E→B (2)
- Single-instance confusions: Am→C, A→B, Bm→F♯, B→D♯, D→A, G→B

Root cause: weak higher-fret voicings confused with low-position ones.

### TaylorNylon (16 unique confusions):
- Fm→G♯ (7), F→A (6), D→A (6), Fm→C (4), Em→E (4)
- Remaining 11 with ≤2 instances

Root cause: large harmonic overlap in nylon timbre; classical voicings less distinctive under FFT.

## Provenance & Licensing

Both datasets sourced from legacy Cantus codebase at `mossgroves-cantus` (Mossgrove-owned, internal research). Original GADA + TaylorNylon recordings collected for Music Information Retrieval research; used here for on-device feature validation only. No commercial distribution.

## Notes for Maintenance

- WAVs committed as-is (no processing)
- JSON sidecars machine-generated, safe to regenerate via `MCC_GENERATE_SIDECARS=1 swift test --filter SidecarGenerationTests`
- Do not increase thresholds without corresponding improvements to AudioExtractor source code
- If AudioExtractor major version changes, re-measure accuracy and update thresholds + this document
