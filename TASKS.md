# MCC Tasks

## Active

**0.0.8 AudioExtractor Design Phase** — Scoping AnalysisPipeline subsystem with stateless offline fragment analysis (chord progression, key, tempo, contour from audio URL). Using diagnosis-plan-execute pattern: design spec → peer review → phased implementation with intermediate fixture test. Contour API shape includes onset time, duration, Parsons code, and signed-semitone steps per 2026-04-23 decision. Sanctuary confirmed it uses AVFoundation directly, so contour output is the primary integration surface.

**Governance Bootstrap** — Creating MCC-CODEX.md and TASKS.md (Phase 1 checkpoint, 2026-04-24). Pending Phase 2+: TECHNICAL-ARCHITECTURE.md, CLAUDE.md update, spec backfilling (0.0.7-progression-analyzer.md), ADR backfilling (0001-0004 decision records).

## Next Up

1. **Cantus 0.0.7 Adoption** — Cantus currently on 0.0.5, stable. 0.0.6 adoption attempt (2026-04-22) hit runtime crashes; root cause undiagnosed, work stashed. 0.0.7 adoption pending investigation of 0.0.6 root cause (calibration state parity question). Non-blocking; Cantus remains operational on 0.0.5.

2. **Sanctuary 0.0.7 Adoption** — Sanctuary to adopt ProgressionAnalyzer and DSP subsystems on its own schedule. Non-blocking.

3. **Sendable Audit** — Audit all public DSP types (FFTWrapper, window functions, ChromaExtractor) for Sendable conformance. Regression anchor: PublicAPITests.swift should verify all public types pass Sendable compile checks.

4. **0.0.8 Spec Drafting** — Detailed design spec for AudioExtractor with AnalysisPipeline integration, contour output shape, state machine diagrams, and error handling strategy. Peer review with Chris before implementation begins.

## Backlog

- **Pattern Library Extensibility (0.0.9+)** — User-contributed patterns and JSON-based pattern libraries. Deferred; static 15-pattern library ships with 0.0.7.
- **Key Inference Weights Configuration (0.0.9+)** — Currently internal constants in ProgressionAnalyzer+KeyInference.swift. Deferred until a consumer requests configurable heuristic weights.
- **Transposer Enharmonic Preference (1.0.0)** — User-configurable sharp/flat spelling. Currently fixed (C♯, F♯, G♯, A♯ preferred; D♭, E♭, A♭, B♭ for flats). Deferred to post-1.0.0.
- **Audio Subsystem (deferred indefinitely)** — Engine setup, adaptive noise gate, audio file reading. Sanctuary uses AVFoundation directly per 2026-04-22. Will resurrect if consumer app need is confirmed.

## Recently Shipped

**0.0.7 (2026-04-24)** — ProgressionAnalyzer stateless enum with KeyInference (24-key scoring, 6 heuristic weights) and PatternRecognition (15-pattern library, exact/fuzzy matching). RomanNumeral typed value with Degree/Accidental/Quality nested enums, supporting diatonic and borrowed chord spelling. SongReference value type for pattern citations. RecognizedPattern with MatchType enum. Hashable and Sendable conformance added to MusicalKey, KeyMode, NoteName. PublicAPITests extended with 6 new tests validating public type construction and ProgressionAnalyzer public API. 143 tests passing, no warnings.

**0.0.6.1 (2026-04-22)** — Explicit public initializers added to ChordDetector.Result, IntervalDetector.Result, IntervalDetector.Peak. Issue surfaced by Cantus 0.0.6 adoption attempt: compiler-synthesized memberwise initializers not promoted to public when accessed from external modules. Three new PublicAPITests regression anchors: testChordDetectorResultPublicInit, testIntervalDetectorPeakPublicInit, testIntervalDetectorResultPublicInit.

**0.0.6 (2026-04-22)** — ChordDetection subsystem: ChordDetector (multi-path template matching with agreement scoring), IntervalDetector (root and quality from peak-based chroma), ChordClassifierProvider protocol (ML-based classifier injection), multi-path agreement scoring, template pre-filtering. Comprehensive ChordDetection test suite. Known gap: calibration state differs from Cantus's legacy implementation.

**0.0.5 (2026-04-22)** — All DSP types made public: PitchDetector, ChromaExtractor, CanonicalChromaLibrary, window functions, FFT wrapper, DSPUtilities. ChromaTemplateLibrary protocol for dependency injection. PublicAPITests suite (12 tests) as regression anchor. Cantus adopted 0.0.5 successfully (commit fa97618).

## Process Notes

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

**Last Updated:** 2026-04-24 — Governance bootstrap Phase 1 in progress. Pending Phase 1 checkpoint approval before Steps 3–8 (TECHNICAL-ARCHITECTURE, CLAUDE.md update, spec/ADR backfilling, workspace coordination).
