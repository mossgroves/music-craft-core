# MCC Tasks

## Active

None blocking. All releases through 0.0.9 complete on main.

## Next Up

1. **0.0.9.1 Patch Release (Real-Audio Fixtures)** — Bundle deferred real-audio fixtures from both 0.0.8 and 0.0.9 into one combined fixture release. Ground-truth evaluation for AudioExtractor (chord detection, key inference, melodic contour on live recordings) and BeatTracker/TempoEstimator (beat accuracy, tempo estimation on real audio). Coordinate with Sanctuary and Cantus production feedback to validate algorithms on their use cases.

2. **Consumer Adoption Sweeps** — Cascade 0.0.9 adoption to active consumer projects:
   - Cantus 0.0.7+0.0.8 bundled adoption (deferred from previous session; stash@{0} forensic review complete per decisions/stash-0-forensic-review-2026-04-25.md)
   - Sanctuary Phase D search integration (lyric matching on LyricsExtractor tokens, rhythm-aware analysis with BeatTracker/TempoEstimator)
   - Guitar Atlas MCC 0.0.8 adoption (Phase D unblocked by AnalysisPipeline)

3. **0.1.0 or 0.0.10 Planning** — Decide scope: voice/vocal features (vocal range, vibrato, voice type classification), structure analysis (section segmentation), spectral analysis (MFCC foundation), or AnalysisResult JSON bundled record. See Capability Areas in CODEX.md for complete deferred backlog.

## Backlog

Organized by MIR Capability Area (see CODEX.md for complete roadmap and status definitions).

### Tonal analysis

- Modulation detection across a piece — deferred
- Secondary dominants and full chromatic functional analysis — deferred

### Pitch and monophonic analysis

- (All planned items in this area are planned-for-0.0.8; none deferred to backlog)

### Rhythm analysis

- Downbeat detection — deferred
- Meter / time signature inference — deferred
- Spectral flux onset detection — designed; deferred (future MCC DSP enhancement beyond 0.0.8 energy-based onset)
- Tempogram + Viterbi beat tracking (alternative to 0.0.9 autocorrelation) — designed; deferred to post-0.1.0
- ML-based beat detection via Core ML — designed; deferred to post-0.1.0

### Structure analysis

- Section segmentation (verse / chorus / bridge boundaries) — designed; deferred until rhythm + tonal are stable. Likely post-0.1.0.
- Repetition / motif detection — deferred

### Timbral and spectral analysis

- MFCCs (Mel-frequency cepstral coefficients) — designed; deferred. Foundation for vocal feature extraction and instrument classification.
- Spectral centroid, rolloff, flatness — designed; deferred. Pair with MFCCs in a future spectral subsystem release.

### Voice and vocal analysis

- SpeechAnalyzer iOS 26+ upgrade to LyricsExtractor — designed; deferred to 0.0.10 when iOS 26 adoption broadens. Feature detection in 0.0.9 prepares for future upgrade to per-token confidence.
- Vocal range and tessitura — designed; deferred. Computed from F0 distribution.
- Pitch stability over sustained notes — designed; deferred. Standard deviation of F0 within held notes.
- Vibrato analysis: rate, extent, regularity — designed; deferred. Computed from F0 over time via autocorrelation or FFT of the F0 curve.
- Voice type classification: tenor / baritone / bass / soprano / mezzo / alto — designed; deferred. Threshold-based initial implementation using vocal range, tessitura, and FHE thresholds. CoreML refinement later if accuracy warrants.
- Vocal timbre features: spectral brightness, breathiness (spectral flatness), warmth — deferred. Depend on MFCC infrastructure.
- Onset density and phrase length distribution — deferred. Useful proxies for breath control and vocal articulation.

### Music theory primitives

- Tuning value type with preset library (Standard, Drop D, DADGAD, etc.) — deferred. Lifted when a non-Cantus consumer needs guitar-aware fretboard logic.
- TunerStringMatcher (nearest-string + cents-offset given a Tuning) — deferred. Lifts with Tuning.
- Pattern library extensibility (0.0.9+) — User-contributed patterns and JSON-based pattern libraries. Static 15-pattern library ships with 0.0.7.
- Key inference weights configuration (0.0.9+) — Currently internal constants. Deferred until a consumer requests configurable heuristic weights.
- Transposer enharmonic preference (1.0.0) — User-configurable sharp/flat spelling. Currently fixed. Deferred to post-1.0.0.

### Higher-order analysis output

- AnalysisResult JSON-shaped bundled record — designed; deferred. Probable 0.0.9 or 0.1.0 capability.

### Consumer adoption and coordination

- Cantus 0.0.7 adoption — Cantus currently on 0.0.5, stable. 0.0.6 adoption attempt hit runtime crashes; work stashed for forensic review. Non-blocking; will attempt 0.0.7 adoption separately on Cantus's schedule.
- Sanctuary 0.0.7 adoption — Yellow slice; non-blocking. Phase C slices 9–12 (AudioExtractor integration) remain blocked on 0.0.8.
- Forensic review of Cantus 0.0.6 adoption stash — Root cause of runtime crashes not yet diagnosed. Lower priority than pushing 0.0.8 forward.
- 0.1.0 tag after 0.0.8 ships clean — Mark extraction phase complete and readiness for first 1.x pre-release cycle.

## Recently Shipped

**0.0.9 (2026-04-26)** — Voice subsystem (LyricsExtractor wrapping SFSpeechRecognizer for on-device lyric transcription) and Rhythm expansion (BeatTracker and TempoEstimator using onset strength autocorrelation). LyricsExtractor produces TranscribedToken (timestamped word/phrase tokens with optional confidence for iOS 26+ via SpeechAnalyzer in future releases). BeatTracker detects beat times via autocorrelation-based onset strength signal analysis. TempoEstimator ranks tempo candidates from beats or buffer with harmonic ratio support (double-tempo, half-tempo disambiguation). Structural tests only: 11 LyricsExtractor tests, 11 BeatTracker tests, 13 TempoEstimator/Config tests. Real-audio fixtures deferred to 0.0.9.1 patch. Total: 279 tests passing. Tier 1 release: diagnosis-plan-execute pattern with design spec (specs/0.0.9-lyrics-and-beat.md, commit 6688fda) and four Chris-approved decisions (iOS 17+ target, autocorrelation algorithm, independent subsystems, real-audio fixtures deferred).

**0.0.7 (2026-04-24)** — ProgressionAnalyzer stateless enum with KeyInference (24-key scoring, 6 heuristic weights) and PatternRecognition (15-pattern library, exact/fuzzy matching). RomanNumeral typed value with Degree/Accidental/Quality nested enums, supporting diatonic and borrowed chord spelling. SongReference value type for pattern citations. RecognizedPattern with MatchType enum. Hashable and Sendable conformance added to MusicalKey, KeyMode, NoteName. PublicAPITests extended with 6 new tests validating public type construction and ProgressionAnalyzer public API. 143 tests passing, no warnings.

**0.0.6.1 (2026-04-22)** — Explicit public initializers added to ChordDetector.Result, IntervalDetector.Result, IntervalDetector.Peak. Issue surfaced by Cantus 0.0.6 adoption attempt: compiler-synthesized memberwise initializers not promoted to public when accessed from external modules. Three new PublicAPITests regression anchors: testChordDetectorResultPublicInit, testIntervalDetectorPeakPublicInit, testIntervalDetectorResultPublicInit.

**0.0.6 (2026-04-22)** — ChordDetection subsystem: ChordDetector (multi-path template matching with agreement scoring), IntervalDetector (root and quality from peak-based chroma), ChordClassifierProvider protocol (ML-based classifier injection), multi-path agreement scoring, template pre-filtering. Comprehensive ChordDetection test suite. Known gap: calibration state differs from Cantus's legacy implementation.

**0.0.5 (2026-04-22)** — All DSP types made public: PitchDetector, ChromaExtractor, CanonicalChromaLibrary, window functions, FFT wrapper, DSPUtilities. ChromaTemplateLibrary protocol for dependency injection. PublicAPITests suite (12 tests) as regression anchor. Cantus adopted 0.0.5 successfully (commit fa97618).

## Process Notes

**Backlog Organization** — Backlog items are now organized by Capability Area for alignment with MCC-CODEX.md. This structure makes roadmap visibility clear: items under a given area can be grouped into a release, and the status legend (shipped/planned/designed/deferred/out-of-scope) distinguishes where each lives in MCC's evolution. For detailed descriptions and rationale, see CODEX.md Capability Areas section.

**Diagnosis-Plan-Execute Pattern** — Validated by 0.0.7 delivery. For non-mechanical extractions (state machines, complex composition), this three-phase approach prevents unforeseen friction:
1. **Diagnosis:** Understand the feature in its original context, document assumptions, identify risk areas.
2. **Plan:** Design spec with peer review before any code lands.
3. **Execute:** Phased implementation with intermediate fixture tests at the highest-risk transition (e.g., ProgressionAnalyzer integration test [C,G,Am,F]→[I,V,vi,IV] as dictionary key).

This replaces the earlier "extract then integrate" loop with upfront design. Cost: slower start. Benefit: fewer adoption-time surprises and faster consumer integration once shipped.

**Grounding and Assumption Discipline** — MCC follows mossgroves/lore foundation/MOSSGROVE-GROUNDING.md. Every non-trivial claim about MCC code, API shape, or consumer state anchors to file reads, git log, or tool results. Hallucination audits in release specs list verified claims separately from inferences. When a document conflicts with observed state (e.g., CHANGELOG vs. source), surface and reconcile rather than silently trusting the document.

**Public API Surface Validation** — PublicAPITests.swift validates all public types are constructible and consumable from external modules without `@testable import`. This is a regression anchor preventing accidental privatization. Every new public type gets at least one PublicAPITests entry.

**Consumer Adoption Workflow** — After shipping an MCC release:
1. Tag and push to GitHub.
2. Update workspace coordination docs (mcc.md, cross-project-log.md).
3. Notify consumer app owners with clear migration guidance in CHANGELOG.
4. Collect adoption feedback; if adoption hits friction, investigate root cause and apply diagnosis-plan-execute to next release.

**Commit Messages** — Yellow/red decisions include rationale in commit body (not just subject line). Example: "Add Sendable conformance to NoteName — required by MusicalKey Sendable conformance for ProgressionAnalyzer pub API."

**Version Bumping** — musicCraftCoreVersion in Version.swift must match CHANGELOG.md heading and git tag. Test failure (testVersionIsSet) catches drift. One source of truth: the CHANGELOG.md heading; Version.swift and git tags follow.

---

**Last Updated:** 2026-04-25 — 0.0.8 AudioExtractor design spec drafted and approved by Chris; in Sanctuary review.
