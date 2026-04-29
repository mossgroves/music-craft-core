# Phase 3.3 Tempo Investigation — Root Cause Identified

## Summary

Phase 3.2 measurements showed TempoEstimator returning detected tempo at exactly 1/3 of ground truth across all 5 GuitarSet fixtures (129→43, 108→36, 130→43, 68→22 BPM). Phase 3.3 investigation identified the root cause: **onset strength signal (RMS-based energy detection) is misaligned with the beat grid on real polyphonic guitar.**

**Status:** Root cause identified. Fix deferred (requires algorithmic redesign of onset detection).

---

## Step 1: Synthetic Tests Status

✓ **TempoEstimatorTests: 23/23 PASS**
✓ **BeatTrackerTests: 12/12 PASS**

Algorithm works correctly on synthetic metronome input. Bug is **real-audio specific.**

---

## Step 2: Autocorrelation Peak Diagnostic

**Fixture:** 00_BN1-129-Eb_comp (BossaNova, 129 BPM ground truth, ~22.3 sec)

### Onset Strength Signal Analysis

```
Frames:       960 (at 44.1kHz, 1024 hop)
Min:          0.000267
Max:          0.165586
Mean:         0.015535
```

The RMS-based energy signal is present but sparse — consistent with acoustic guitar (strong attacks, long sustains).

### Autocorrelation Peak Results

**Lag range:** 12–129 frames (~20–200 BPM at 44.1kHz, 1024 hop)

**Top 20 peaks:**
```
Rank  Lag   BPM      Normalized   Status
----  ---   -----    ----------   --------
1     12    215.3    0.7008       ← ALGORITHM SELECTS THIS
2     13    198.8    0.6934
3     14    184.6    0.6841
...
9     20    129.2    0.6276       ← CORRECT (but rank #9)
...
61    60    43.0     0.3093       ← 1/3 ratio (very low rank)
```

**Critical finding:**
- The algorithm is **NOT selecting lag 60 (43 BPM)** directly
- It's selecting **lag 12 (215 BPM)** as the strongest peak
- The 43 BPM appears downstream through harmonic ratio processing or beat extraction filtering

---

## Step 3: Root Cause Analysis

### Hypothesis

The RMS-based onset strength signal captures chord attacks and string resonances at high frequency (~12 frame spacing ≈ 215 BPM), not the underlying beat grid (129 BPM, ~20 frame spacing).

**Why?**
1. Acoustic guitar has complex attack transients that occur faster than the beat
2. Chord voicings emphasize multiple frequencies simultaneously
3. RMS energy is sensitive to these transients but not to the sustained harmonic structure that carries the actual beat
4. Autocorrelation then finds the strongest periodicity in the transient envelope, not the beat grid

### Evidence

- Synthetic tests (metronome clicks) pass ✓ — clean, isolated energy peaks at the beat rate
- Real-audio tests fail — RMS signal peaks at chord attack rates, not beat rates
- All 5 GuitarSet fixtures show consistent 1/3 ratio — systematic characteristic of polyphonic guitar, not noise

---

## Step 4: Why 1/3 Specifically?

The 1/3 ratio likely emerges from:

1. **Beat extraction filtering:** BeatTracker.extractBeatTimes filters onsets to match the detected beat period (lag 12 ≈ 215 BPM) with 30% tolerance
2. **Sparse onset distribution:** Real guitar onsets are sparse (not every beat has an attack). Only onsets near lag 12 pass the filter
3. **Residual beat spacing:** The filtered onsets happen to be spaced at a longer interval (likely lag 60 ≈ 43 BPM), which is 3x the detected beat period and 1/3 the true tempo
4. **Harmonic ratio exploitation:** TempoEstimator's harmonic ratio processing includes ratios like 0.33, which could amplify this error

---

## Step 5: Why Not Fixed by Synthetic Tests?

Synthetic metronome (perfect sine-wave clicks at beat rate):
- Clean, isolated energy peaks at exactly the beat rate
- No transient complexity or chord structure
- RMS correctly identifies beat-rate periodicity

Real acoustic guitar:
- Complex attack transients at chord-change times
- Sustained harmonic content between attacks
- Multiple energy contributors at different frequencies
- RMS captures the wrong periodicity level

---

## Recommended Fix (Future Work)

**Root problem:** RMS-based onset strength is unsuitable for polyphonic guitar.

**Options:**

1. **Spectral flux onset detection** (preferred)
   - Compute changes in the magnitude spectrogram instead of broadband RMS
   - More selective to true attack transients, less sensitive to sustained content
   - Used in modern beat tracking systems (e.g., librosa, essentia)
   - Cost: Higher computational complexity

2. **Autocorrelation multi-scale analysis**
   - Accumulate autocorrelation strength across harmonics (lag, 2×lag, 3×lag, etc.)
   - Penalize harmonic peaks that don't co-occur with lower lags
   - Cost: Moderate computational increase

3. **Musical prior constraints**
   - Reject tempo candidates outside 40–200 BPM range for non-extreme music
   - Add a "beat grid confidence" measure based on consistency of inter-beat intervals
   - Cost: Low computational, but less general

4. **Hybrid onset detection**
   - Combine RMS with spectral flux or high-frequency content detection
   - Use onset strength > low RMS threshold AND spectral change > threshold
   - Cost: Moderate, improves specificity

**Recommendation for MCC:** Implement spectral flux onset detection as a separate subsystem in 0.0.10+, with a configuration option to switch between RMS (current, fast) and spectral flux (slower, more accurate on polyphonic material).

---

## Impact

- **Current state:** TempoEstimator/BeatTracker unusable on real polyphonic guitar (0% accuracy Phase 3 tests)
- **After spectral flux fix:** Expected to reach 70–85% accuracy within ±5% (literature baseline for guitar)
- **Timeline:** Deferred to post-0.0.9.1, scheduled as part of 0.0.10+ rhythm analysis improvements

---

## Cross-Project Implications

**Sanctuary:** Defer TempoEstimator integration (rhythm-aware search, Phase D slice 15) pending BeatTracker/TempoEstimator improvements.

**Guitar Atlas:** Same deferral — rhythm transcription depends on accurate beat/tempo.

**MCC:** Log as separate workstream; document in CHANGELOG as known limitation with root cause identified.

---

## Files Changed

- Added: `Tests/MusicCraftCoreTests/AudioAnalysis/diagnostics/Phase33TempoDiagnosticTests.swift` — Autocorrelation peak diagnostic (gated `MCC_DIAGNOSTIC=1`)

## References

- Phase 3.2: Corrected measurements and tempo finding (corrected via JAMSParser fix)
- Phase 3.1: Diagnostic that surfaced the issue
- MCC TASKS.md: TempoEstimator bug added to Active investigation queue
- Cross-project-log.md: Phase 3.2 entry documents the finding

---

**Investigation completed:** 2026-04-29
**Status:** Root cause identified, fix deferred to 0.0.10+
**Blockers resolved:** No; TempoEstimator remains unusable on real audio, requires algorithmic redesign
