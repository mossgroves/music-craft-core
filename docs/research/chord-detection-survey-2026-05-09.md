# Chord Detection — Field Survey and MCC Path Forward

**Date:** 2026-05-09
**Status:** Research synthesis. No implementation pending in this commit; see `mossgroves-claude-workspace/handoffs/chord-detection-rebuild-2026-05-09.md` for the execution plan.
**Author:** Composed in Claude.ai planning session, committed via Claude Code.

## Executive Summary

MCC's current chord detector is built on 2010-era foundations: chroma-feature template matching with an optional shallow CoreML classifier as a secondary signal. The Phase 2.8 measurement experiment (branch `phase-2-8-port-recovery`, 2026-05-09) confirmed the missing CoreML classifier accounts for ~16 percentage points of the observed accuracy gap, but injecting it leaves overall root accuracy at 56% (GADA) / 48% (TaylorNylon) — well below the legacy Cantus Stage 2 numbers (99.7% / 88.1%) and below what modern techniques achieve on solo-instrument audio.

The remaining gap is not a bug to fix in the existing pipeline. It reflects a fundamental architectural choice (chroma + template matching) that the field has moved past. State-of-the-art chord recognition uses CNN acoustic models on log-frequency or constant-Q spectrograms, decoded with sequence models (CRF, RNN, or transformer). Sanctuary's domain — single nylon-string acoustic guitar, single user, clean mono input — is dramatically easier than the standard pop-music benchmarks. Modern techniques applied to this domain should achieve 90–95% root accuracy on triads.

## Field State (2025–2026)

State-of-the-art automatic chord estimation (ACE) on standard pop-music benchmarks (Isophonics, McGill Billboard) has been stagnant at ~80% Weighted Chord Symbol Recall on the MajMin vocabulary for roughly a decade. Recent 2024–2025 papers (LLM chain-of-thought reasoning, BACHI iterative decoding) add 1–3 percentage points, not breakthroughs. Even human annotators disagree on chord labels by 10–15% on the same songs (Humphrey & Bello 2015; Koops et al.; Ni et al. 2013), which sets a soft ceiling on what "ground truth" even means.

This stagnation is partly a benchmark-coverage issue: the standard datasets are dominated by pop/rock with mixed instrumentation, vocals, drums, bass. Models trained on this distribution do not transfer cleanly to solo-instrument input.

Sanctuary's input is the easy end of the field by a wide margin. One person, one nylon-string acoustic, mono microphone, no source separation needed. Domain-restricted training and inference should perform substantially better than the published 80% ceiling.

## Seven Technical Findings

### 1. Chroma is a dated input representation

MCC's pipeline reduces audio to a 12-dimensional chroma vector before chord classification. This discards most of the harmonic information present in the original spectrogram. Modern systems consume one of:

- **Constant-Q transform (CQT)**: 24 bins per octave over 7 octaves (~168 dimensions), log-spaced to align with semitones. Used in Korzeniowski/Widmer 2016, Sigtia/Boulanger-Lewandowski/Dixon 2015, multiple later works.
- **Log-frequency STFT spectrogram**: linearly scaled in frequency but log-bucketed; Cheuk et al. 2020 (nnAudio) reports +8.33% transcription accuracy from input representation alone, no architecture change.

Chroma is computed from these spectrograms; feeding the classifier the raw spectrogram lets the network learn its own internal representation, typically much cleaner than hand-computed chroma.

### 2. CNN acoustic model, not template matching

MCC's `ChordDetector.matchChord` compares an extracted chroma vector against canonical chord templates. The CoreML classifier (when present) is one of three scoring stages weighted at 50% of the combined score. This approach was state-of-the-art around 2010–2014 but has been displaced.

Modern pipelines train a fully convolutional network end-to-end on labeled audio. The network input is typically a context window of spectrogram frames (the network sees a few hundred ms of audio at once); the output is a per-frame chord prediction. This is what Korzeniowski & Widmer 2016 ("A Fully Convolutional Deep Auditory Model for Musical Chord Recognition", IEEE MLSP) implements, and what `madmom.features.chords.CNNChordFeatureProcessor` ships as the open-source reference.

### 3. CRF (or similar) for sequence decoding

MCC currently picks one chord per onset-bounded segment by highest confidence. This treats each segment independently. Modern systems run the acoustic model frame-by-frame (typically 10 fps) and decode the chord sequence using a Conditional Random Field, HMM, or RNN that has learned chord-transition statistics. The temporal model smooths over per-frame errors and produces coherent segment boundaries.

`madmom.features.chords.CRFChordRecognitionProcessor` is the canonical open-source CRF decoder. The 2018 follow-up paper (Korzeniowski & Widmer, "Improved Chord Recognition by Combining Duration and Harmonic Language Models", ISMIR 2018) extends this with explicit duration and harmonic language models for further gains.

### 4. Domain-specific training data is on hand

We already have ~500 labeled solo-guitar audio clips:

- **GuitarSet** (Xi et al., ISMIR 2018): 360 clips of 30s solo acoustic guitar with full JAMS annotations including chord labels, located in `Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/guitarset/`. CC-BY 4.0 licensed (Zenodo record 3371780).
- **TaylorNylon**: 109 nylon-string fixtures with chord ground truth (in MCC test fixtures).
- **GADA**: 32 acoustic fingerstyle clips with chord ground truth (in MCC test fixtures).

This is enough to fine-tune a model substantially specific to Sanctuary's domain. Pitch augmentation (transposing audio ±6 semitones during training, shifting labels accordingly) effectively multiplies this data by 13× and produces key-invariant representations.

### 5. Pitch augmentation is essentially free accuracy

Multiple papers (Humphrey & Bello 2012; Korzeniowski & Widmer 2016; Lardet 2025) report pitch augmentation as one of the largest single training improvements available. Models trained without it learn key biases from the training distribution; with it, they generalize across keys uniformly.

### 6. Apple's path is real

The iOS-native pipeline for this kind of work is well-supported:

- **SoundAnalysis framework**: real-time audio analysis on-device, runs CoreML models against streaming audio.
- **CreateML** with `MLSoundClassifier`: trains a sound classifier from a labeled audio directory, outputs `.mlmodel` directly. Built on `MLAudioFeaturePrint`, Apple's pre-trained audio embedding model.
- **CoreML**: runs the trained model on iPhone, low-latency, no server roundtrip, no privacy concerns.

Chord AI (commercial competitor, App Store) demonstrates that on-device deep-learning chord recognition on iPhone is viable in 2026. They run source separation (4 stems), beat tracking, and chord recognition all on-device. The technical pattern is well-trodden.

### 7. The Phase 2.8 +16pp result is consistent with field expectations

The legacy CoreML model in `mossgroves-cantus/ChordClassifier.mlmodel` is a small (~20 KB) classifier taking 12-dimensional chroma input. By 2025 standards this is a tiny, simple model — the field has moved to taking spectrograms or CQT as input and learning chroma-equivalent representations inside the network. The +16pp recovery from injecting this classifier puts MCC into chroma-classifier territory; the 80–95% range opens up only when the network has access to richer input.

## Three Paths Forward

### Path A — Port `madmom`'s CNN+CRF model to CoreML

Korzeniowski/Widmer 2016 model is a few MB; madmom's package licensing should be verified before integration (mixed BSD/MIT depending on module). Conversion path: extract architecture and weights from madmom's pickle format, re-implement in PyTorch or Keras, convert to CoreML via `coremltools`.

**Effort:** Several days of model-porting work. **Accuracy on Sanctuary's domain:** uncertain — model was trained on Beatles/RWC pop music; distribution mismatch likely caps accuracy on solo guitar relative to its published headline numbers.

### Path B1 — CreateML `MLSoundClassifier` on guitar-specific data (recommended)

Use Apple's intended workflow: slice GuitarSet + GADA + TaylorNylon recordings into per-chord audio segments using their JAMS annotations; pitch-augment to ±6 semitones (13× multiplier); train an `MLSoundClassifier` model in CreateML; export `.mlmodel` directly; wire into MCC via existing `ChordClassifierProvider` protocol initially; refactor `AudioExtractor` to skip the chroma path and feed audio segments directly to the model in a follow-up.

**Effort:** Two focused training-validation cycles, no Python infrastructure required (CreateML is Xcode-native). **Accuracy on Sanctuary's domain:** projected 85–92% root for triads (inference, not measured).

### Path B2 — Custom CNN+CRF in PyTorch, convert to CoreML

Replicate Korzeniowski/Widmer's architecture, train from scratch on guitar data, convert to CoreML. Higher ceiling than B1 because CRF temporal smoothing is included and the architecture is purpose-built for sequence prediction. Higher cost: requires Python training infrastructure, possibly cloud compute for sweeps, and `coremltools` conversion work.

Defer until B1 is exhausted. B1 likely meets the product's needs.

### Path C — Train from scratch, custom architecture

Highest ceiling, highest cost. Not warranted for the current product stage.

## Recommendation

**Path B1.** Reasons:

- Plays to Apple's intended on-device ML workflow.
- Tooling is built-in (CreateML, no Python pipeline).
- Domain-specific from day one (training data is solo guitar, not pop mixes).
- Output is CoreML `.mlmodel` directly, no conversion step.
- Accuracy ceiling (projected ~92%) is plausibly enough for "Cantus listened and got it right" UX without overclaiming.
- Decomposes cleanly into autonomous Claude Code phases with deterministic verification checkpoints.

The architectural shift (chroma → CNN-direct) is worth doing regardless of which model fills the new pipeline. If B1 falls short of the accuracy goal, B2 becomes the next step from the same architectural base.

## Open Questions for Implementation

1. **Chord vocabulary:** start with MajMin (24 classes) for simplicity, or include sevenths (~40 classes) from the outset?
2. **Segment length:** per-chord audio segments are variable-length. Pad to fixed length, or use variable-length input?
3. **Confidence framing:** how should the model's softmax confidence translate to Sanctuary's "Cantus suggests" UX? Top-1, top-3, threshold-based?
4. **Where does the model live?** MCC bundle resource, or Sanctuary-injected provider?
5. **Bass-root path:** does the new model make the bass-root question moot, or does it remain useful as an auxiliary signal for low-confidence cases?

## Hallucination Audit

Per `mossgroves-lore/foundation/MOSSGROVE-GROUNDING.md` design-spec discipline, every non-trivial claim is anchored or labeled as inference.

**Verified in-session (file reads or tool outputs):**

- Phase 2.8 measurement numbers (40.6% / 56.2% / 31.2% / 47.7%): verified against `mossgroves-music-craft-core/docs/diagnostics/phase-2-8-port-recovery.md` Phase 5 measurement table.
- Legacy three-stage scoring weights (50%/30%/20%): verified against `mossgroves-cantus/Cantus/Core/ChordDetector.swift` `combinedRaw` formula in `matchChord`.
- Legacy `ChordClassifier.mlmodel` size (~20 KB; exact 19,969 bytes): verified by file metadata on `mossgroves-cantus/ChordClassifier.mlmodel`.
- MCC's `AudioExtractor` calls `ChordDetector.detectChord(chroma:)` and does not pass a `classifierProvider`: verified against `mossgroves-music-craft-core/Sources/MusicCraftCore/AnalysisPipeline/AudioExtractor.swift` and the Phase 2.8 diagnostic doc.
- GuitarSet location in MCC test fixtures: verified by directory listing on `Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/real-audio/`.

**Cited from external literature, not independently re-verified in-session:**

- ~80% MajMin WCSR field benchmark and human-annotator disagreement of 10–15%: cited from web search results (Humphrey & Bello 2015; Koops et al.; Ni et al. 2013). The general field-stagnation framing is well-established but the specific numbers are inference based on cited literature, not in-session verification of the source papers.
- Cheuk et al. 2020 nnAudio "+8.33% transcription accuracy from input representation alone": cited from web search; not independently verified by reading the paper.
- Korzeniowski & Widmer 2016 architecture description and madmom's `CNNChordFeatureProcessor` / `CRFChordRecognitionProcessor` API: cited from madmom documentation as accessed via web search; not independently verified by running the library.
- Korzeniowski & Widmer 2018 ISMIR follow-up adding duration and harmonic language models: cited from search; not independently verified.
- Sigtia/Boulanger-Lewandowski/Dixon 2015 ISMIR hybrid RNN paper: cited from search; not independently verified.
- Lardet 2025 thesis on pitch augmentation gains: cited from search; not independently verified.
- GuitarSet license (CC-BY 4.0) and Zenodo record (3371780): cited from prior MCC work and public dataset documentation; not independently re-verified in-session.
- CreateML `MLSoundClassifier` and `MLAudioFeaturePrint` capabilities: cited from Apple's developer documentation as accessed via web search; not independently verified by running the framework.
- Chord AI commercial app capabilities (on-device, source separation into 4 stems): cited from public App Store listing and chordai.net; not independently verified by purchasing or testing the app.

**Projections, labeled as inference:**

- "Path B1 accuracy: 85–92% root for triads on solo nylon guitar": projection based on domain-restriction reasoning (single instrument, clean recording, ~6500 augmented training samples). Not yet measured.
- "Path A on Sanctuary's domain caps below its published headline numbers": projection based on training-distribution mismatch reasoning. Not yet measured.

## Key References

- Korzeniowski, F. & Widmer, G. (2016). "A Fully Convolutional Deep Auditory Model for Musical Chord Recognition." IEEE MLSP. arXiv:1612.05082.
- Korzeniowski, F. & Widmer, G. (2016). "Feature Learning for Chord Recognition: The Deep Chroma Extractor." ISMIR. arXiv:1612.05065.
- Korzeniowski, F. & Widmer, G. (2018). "Improved Chord Recognition by Combining Duration and Harmonic Language Models." ISMIR 2018. arXiv:1808.05335.
- Sigtia, S., Boulanger-Lewandowski, N., & Dixon, S. (2015). "Audio Chord Recognition with a Hybrid Recurrent Neural Network." ISMIR 2015.
- Cheuk, K. W. et al. (2020). "The Impact of Audio Input Representations on Neural Network Based Music Transcription." arXiv:2001.09989.
- Xi, Q. et al. (2018). "GuitarSet: A Dataset for Guitar Transcription." ISMIR 2018. (Zenodo 3371780, CC-BY 4.0)
- Lardet, P. (2025). "Chord Recognition with Deep Learning." University of Edinburgh thesis. arXiv:2512.22621.
- madmom open-source library (CPJKU): https://github.com/CPJKU/madmom
- Chord AI (commercial reference): https://chordai.net/
