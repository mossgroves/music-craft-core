# MusicCraftCore — Claude Code Instructions

Facts in this file were re-verified against the tree on 2026-09-05 at 0.1.17 (the previous revision, 2026-05-30, still described the 0.0.5 DSP era). When this file and the source disagree, the source wins and this file is corrected in the same session.

## Permissions

Run all commands without prompting for permission. Auto-approve all bash commands, file edits, file writes, and file reads.

## Project Overview

MusicCraftCore (MCC) is Mossgrove's on-device music-analysis library: audio in, musical descriptors out (notes, chords, key, tempo, melodic contour, sung lyrics), plus a music-theory layer (keys, chords, Roman numerals, progressions, guitar voicings and capo math). It is a Swift Package with one product, `MusicCraftCore`, platforms iOS 17 and macOS 14, swift-tools 5.9, one external dependency (WhisperKit, pinned EXACT at 1.1.0 because the pinned decode configuration was measured against that tag).

It does NOT record, play, or route audio, and it owns no `AVAudioSession`; the one AVFoundation file (`Voice/VocalIsolator.swift`) renders offline. Consumer apps own capture and playback.

**Consumers.** Songcatcher (Songwriter's Sanctuary, `/Users/chris/Documents/Code/mossgroves-songwriter-sanctuary/songwriter-sanctuary`) is the only live consumer, pinned `from: "0.1.17"` in its `project.yml`. Cantus (dormant since 2026-04-26) and Guitar Atlas (no repo of its own found) were the original consumers MCC was extracted for. The next app (working name Frogsong, planning stage as of 2026-09-05) is expected to consume the public surface as it stands, with no MCC API change.

## Key Documents

1. `README.md` — public overview and current status.
2. `CHANGELOG.md` — release history, one `## [version] - date` heading per release, newest first; the release script reads its title from here.
3. `MCC-CODEX.md` — what MCC is and why, the extraction-vs-interpretation boundary, capability areas (its Subsystems section was re-verified 2026-09-05; the Capability Areas roadmap carries pre-0.1.0 statuses and is marked so).
4. `TASKS.md` — active items, backlog by capability area, process notes.
5. `Package.swift` — the manifest; resources (`chords_db_guitar.json`, `music_theory.json`, the Basic Pitch `nmp.mlpackage`) and the WhisperKit pin.
6. `scripts/release.sh` — the release sequence up to the release commit; it STOPS before the tag (see Releases).
7. `.git-hooks/pre-push` and `.git-hooks/known-failing-tests.txt` — the suite gate on every push to main, with the allowlist of deliberate failures.
8. `specs/` — design specs 0.0.8 through 0.0.14; `docs/security/` — third-party code reviews (`basic-pitch-2026-05-31.md` is the model); `docs/research/`, `docs/diagnostics/`, `docs/AUDIO_TESTING_STRATEGY.md` (a 2026 draft).
9. `.claude/phase-report-template.md` — copied from the lore; the lore copy is the source of truth.

Portfolio standards from `/Users/chris/Documents/Code/mossgroves-lore` (edits there are RED, Chris's explicit direction only):

- `foundation/MOSSGROVE-LORE.md` for development standards, voice, quality checklists and Phase Discipline.
- `foundation/MOSSGROVE-FORGE.md` for lifecycle stages and release readiness.
- `foundation/MOSSGROVE-GROUNDING.md` for grounding and assumption discipline.
- `foundation/MOSSGROVE-CAPABILITY-FIT.md` for cross-component integration audits.
- `foundation/MOSSGROVE-SESSION-REPORTS.md` for session report structure.

## Current State

**Version 0.1.17**, tagged and pushed 2026-09-03 on Chris's word ("tag it"). 117 commits on `main`. 523 `func test` declarations across 66 test files; the 2026-09-03 push ran 521 tests through the pre-push hook with only the two allowlisted GuitarSet failures.

**The one audio engine since 0.1.0 (2026-06-01):** Spotify's Basic Pitch (a bundled Core ML model) transcribes notes; chords, key and contour are derived note-natively. The hand-rolled DSP chord path (`PitchDetector` YIN, `ChromaExtractor`, `ChordDetector`, `IntervalDetector`, `ChordClassifierProvider`, `CanonicalChromaLibrary`, `ChromaTemplateLibrary`, `NoiseCalibrator`) was DELETED at 0.1.0; any document that still names those types as shipped is stale. Lyrics come from WhisperKit (whisper-small, pinned decode config, since 0.1.6) with Apple's Speech framework as the fallback, pinned on-device since 0.1.15; 0.1.17 added a decode-time repetition brake and a run guard. The melodic contour of a sung take can be traced from a separated voice (`VocalIsolator`, 0.1.8).

**Branches not on main** (`rebuild/r1-curation` through `rebuild/r4b-iterations`, `phase-2-8-device-harness`, `phase-2-8-port-recovery`, `docs/diatonic-chord-generator-clarify`) carry the 2026-05 Basic Pitch training rebuild and a device harness; their contents were not re-verified on 2026-09-05. `DeviceTestHarness/` (an Xcode project, last touched 2026-06-06) is likewise unverified.

## Decision Classification and Autonomy

Same three tiers as Songcatcher's CLAUDE.md.

### Green — proceed without rationale
- Documentation, comments, markdown files (README.md, CHANGELOG.md, TASKS.md, MCC-CODEX.md, this file, specs, docs)
- Test fixture data or test infrastructure
- Private/internal symbol additions where no existing symbol is removed or renamed

### Yellow — proceed with rationale in commit body
- Test source files where the change adds new tests without modifying existing assertions
- Internal refactors of non-public symbols
- Non-public types where nothing outside the module references them
- Additive public API (a new type, a new method, a new optional field with a default): anchored to the CHANGELOG entry, and covered by `PublicAPITests`

### Red — stop, wait for Chris
- Any removal, rename, or signature change of a public symbol Songcatcher consumes. The live public surface: `AudioExtractor` (`extract`, `Configuration`, `Result`, `ChordSegment`, `ContourSource`), `BasicPitchTranscriber` (`Transcription`, `TranscribedNote`, `PitchFrame`), `LyricsExtractor` (`Configuration`, `TranscribedToken`, `prepare`), `VocalIsolator`, `NoteChordIdentifier`, the tempo types (`TempoEstimator`, `TempoEstimate`, `BeatTracker`), the MusicTheory value types (`Note`, `NoteName`, `SpelledNote`, `Chord`, `ChordQuality`, `MusicalKey`, `RomanNumeral`, `ProgressionAnalyzer`, `MelodyKeyInference`, `DiatonicChordGenerator`, `ContourNote`, `DetectedNote`, `Transposer`, `TheoryReference`), and the Instruments/Guitar types (`VoicingLibrary`, `GuitarVoicing`, `VoicingPosition`, `VoicingScore`, `CapoCalculator`, `GuitarTuning`). Read `Tests/MusicCraftCoreTests/PublicAPITests.swift` before touching any of them.
- The WhisperKit pin (`exact: "1.1.0"`) and the pinned decode configuration in `Voice/WhisperLyricsEngine.swift`: the measured word-error rates depend on both.
- `Package.swift` platforms, products, or resources.
- File deletions or renames in `Sources/`.
- `git tag`, and any push that carries a tag. **Release tags MUST be 3-component SemVer** (`MAJOR.MINOR.PATCH`). Never a 4th component (`0.0.6.1`, `0.0.10.1`, `0.0.12.1` all had to be re-cut): SwiftPM's `from:` resolution silently ignores them, so version-pinned consumers cannot adopt the release (verified 2026-05-30). A patch takes the next patch number.
- Any open question Chris has not resolved.
- **Integration of third-party code or algorithms without a security review.** Before porting, adapting, or integrating any external code (academic libraries, reference implementations, algorithm papers, models), produce a security analysis covering: (1) code injection vectors; (2) ReDoS in regex patterns; (3) buffer/array handling and bounds safety; (4) dependency analysis and transitive risks; (5) cryptographic or sensitive data handling; (6) exception handling design; (7) known CVEs or advisories. Classify SAFE TO PORT with Swift adaptation notes, or UNSAFE with reasons. File it in `docs/security/` and link it from the implementing commit. `docs/security/basic-pitch-2026-05-31.md` is the worked example.
- Licences: only MIT / BSD / Apache 2.0 / CC0 / CC-BY material may be bundled (portfolio rule). Every bundled third-party item is listed in `NOTICE` and ships its licence text (`BASIC_PITCH_LICENSE.txt`, `Resources/chords_db_LICENSE.txt`).

## Phase Discipline

Follow the lore's `MOSSGROVE-LORE.md` Phase Discipline section. Phase reports use `.claude/phase-report-template.md` (copied from the lore for proximity; the lore is the source of truth if they diverge). Silent scope expansion is a Verification-section failure even when the extra work is correct: every commit the session produced is listed.

## Grounding and Assumption Discipline

MCC follows `foundation/MOSSGROVE-GROUNDING.md`. Every non-trivial claim Claude makes about MCC code, the public API, shipped versions, or the consumer's state anchors to a file read, git log output, or a tool result from the current session. Ungrounded claims are labeled inference.

MCC-specific applications:

1. A release spec or design document ends with a hallucination audit: every non-trivial claim and the file, line, or command that verified it; unverified claims listed separately as inference.
2. Before claiming what a public API does, read the source file and its tests. Tests are the most precise record of intended behavior.
3. Consumer state (what version Songcatcher pins, what it calls, what it needs) is read from the consumer's repo itself: `project.yml` (the pin), `TECHNICAL-ARCHITECTURE.md` ("Dependency shape"), `CHANGELOG.md`. The old `mossgroves-claude-workspace` mailbox is RETIRED (2026-06-16) and is neither read nor written.
4. Reviewing a spec or PR: separate what is grounded in file reads from design opinion.
5. When an MCC document conflicts with the source or the suite, surface the conflict and fix whichever side is wrong; never trust the document silently. (This file was that document on 2026-09-05.)
6. A cited number is comparable only with one measured on the same machine and engine: every accuracy table says where it was measured, and Mac figures are never mixed with phone figures in a headline.

## Architecture Decisions (current)

- **Basic Pitch is the only note source** (0.1.0). `AudioExtractor.extract` runs one transcription and derives chords (`NoteChordIdentifier`, `ChordSequenceDecoder`), key (`ProgressionAnalyzer` over the chords, `MelodyKeyInference` as the no-chord fallback), the melodic-skyline `contour`, and full-polyphony `detectedNotes` from it. `Result`'s shape did not change at 0.1.0; most of `AudioExtractor.Configuration` is vestigial (only `contourSource` is read).
- **Extraction, not interpretation.** MCC returns typed descriptors; meaning, mood and narrative belong to the consuming app (MCC-CODEX "Architectural Boundary").
- **Lyrics: Whisper first, Apple second, both on-device.** `LyricsExtractor` routes to `WhisperLyricsEngine` when a model folder is supplied, else to Apple Speech (SpeechAnalyzer on iOS 26+, `SFSpeechRecognizer` below, pinned `requiresOnDeviceRecognition`). Config law measured in the consumer: never an initial prompt, always the full mix, never the stem.
- **Music theory types are stable** since 0.0.3; the public surface has been additive-only since 0.1.0. A breaking change requires a minor bump and migration guidance in the CHANGELOG.
- **Additive by default.** New capability arrives as a new type or an optional field with a default, covered by `PublicAPITests`, so a consumer's pin can move forward without code changes.

## File Locations (verified 2026-09-05)

```
README.md · CHANGELOG.md · MCC-CODEX.md · TASKS.md · CLAUDE.md · NOTICE · BASIC_PITCH_LICENSE.txt
Package.swift · Package.resolved (gitignored) · scripts/release.sh · .git-hooks/{pre-push,install.sh,known-failing-tests.txt}
Sources/MusicCraftCore/
  Version.swift                      ← musicCraftCoreVersion, moves only through scripts/release.sh
  AnalysisPipeline/AudioExtractor.swift   ← the orchestrator: extract(url:) / extract(buffer:sampleRate:)
  Transcription/BasicPitchTranscriber.swift, BasicPitchDecoder.swift   ← the Core ML note engine
  ChordDetection/NoteChordIdentifier.swift, ChordSequenceDecoder.swift ← note-native chords, Viterbi decode
  DSP/TempoEstimator.swift, TempoEstimate.swift, TempoHistogram.swift, BeatTracker.swift,
      SpectralFluxOnsetDetector.swift, DSPUtilities.swift              ← tempo only; the chord DSP is gone
  MusicTheory/ (20 files)            ← Note, Chord, MusicalKey, RomanNumeral, ProgressionAnalyzer(+KeyInference,
                                        +PatternRecognition), MelodyKeyInference, DiatonicChordGenerator,
                                        ContourNote, DetectedNote, ParsonsCode, Transposer, TheoryReference, …
  Instruments/Guitar/                ← VoicingLibrary (chords-db), GuitarVoicing, VoicingPosition, VoicingScore,
                                        CapoCalculator, GuitarTuning
  Voice/LyricsExtractor.swift, WhisperLyricsEngine.swift, RepetitionBrake.swift, TranscribedToken.swift,
        VocalIsolator.swift          ← sung lyrics (Whisper + Apple fallback), the repetition brake, the stem
  Resources/nmp.mlpackage, chords_db_guitar.json, chords_db_LICENSE.txt, music_theory.json
  Audio/                             ← EMPTY folder; the Audio subsystem was never extracted
Tests/MusicCraftCoreTests/           ← 66 files; PublicAPITests.swift is the public-surface regression anchor;
                                        AudioAnalysis/Fixtures/real-audio/{gada,guitarset,taylor-nylon,lyrics}
specs/ · docs/{security,research,diagnostics}/ · DeviceTestHarness/ (unverified since 2026-06)
```

## Releases

Two tiers, and in BOTH the tag and the push are Chris's word.

### Tier 1 (a new subsystem, a new architecture pattern, a public API change)
1. Diagnosis-plan-execute: a design spec with a hallucination audit → review → phased implementation with intermediate checkpoints.
2. Chris's explicit approval before the tag.
3. The suite passes at the count the spec names.
4. Consumer adoption verified on real audio before the release is called stable.

### Tier 2 (a patch, a single-subsystem addition, an internal refactor, no public API change)
1. Commit hygiene per the classification above; suite green against the allowlist; `PublicAPITests` extended for any public addition.
2. Claude runs the sequence through the release commit on its own; the tag and the push still wait for Chris's word.

### The sequence (the app's `mcc-release` skill is the checklist; this is the MCC half)
1. The change is committed with its tests. The CHANGELOG entry is written and committed: `## [0.1.18] - YYYY-MM-DD` then `### Fixed — <title>` (the script reads the title after the em dash).
2. `scripts/release.sh 0.1.18 --dry-run`, read every line; then `RELEASE_TRAILERS=$'Co-Authored-By: …\nClaude-Session: …' scripts/release.sh 0.1.18`. It checks SemVer, that the version is greater than `Version.swift`, that no such tag exists, that the branch is main and the tree clean, that the CHANGELOG heading exists, runs `swift test` against the allowlist, bumps `Version.swift` and `testVersionIsSet` together, commits `release: 0.1.18 — <title>`, and STOPS. It never tags or pushes.
3. Report the version, title, test summary, commit sha and the printed commands; ask for the word.
4. On his word, exactly as printed: `git tag -a …`, `git push origin main`, `git push origin 0.1.18`. TWO pushes: the pre-push hook exits 0 on the first non-main ref it reads, so `git push origin main 0.1.18` skips the suite (TASKS.md item 0, open; seen on 0.1.14).
5. The consume happens in the app (pin bump, `xcodegen generate`, resolve, the app's `verify-build`, its doc-sync); the app commit is HELD for Chris's device look.

Why the script exists: 0.1.9 through 0.1.15 shipped with `Version.swift` still reading 0.1.8 because the tag was cut without a check. `testVersionIsSet` and the script make the two files move together.

## The pre-push hook

`.git-hooks/pre-push` (symlinked into `.git/hooks` by `.git-hooks/install.sh`, run once per clone) runs `swift test` on every push to main and BLOCKS on a new failure AND on an allowlisted test that now passes (remove its entry in the same commit that fixed it). A build error is judged before the allowlist: nonzero exit with no parsed failures is "nothing ran", not "everything passes" (2026-08-26). Allowlisted today: the two GuitarSet benchmarks (`GuitarSetProgressionTests`, `GuitarSetKeyInferenceTests`), deliberate, "do not lower".

## Known Constraints and Gotchas

- **Two agents or sessions building in this package at once collide** (`swift test` dies with "input file was modified during the build", 2026-09-02). Tell any subagent which repos it may build in; run the session's own builds after a workflow finishes.
- **Synthetic sine fixtures do not reliably transcribe through Basic Pitch** (it is trained on real timbre; `AudioExtractorTests.swift` says so). Real-audio fixtures under `Tests/…/Fixtures/real-audio/` are the ground truth; assert on monophonic material where the analyzer is deterministic.
- **A `.mlpackage` behaves differently under `swift test` and inside an app.** Xcode compiles it to `nmp.mlmodelc`; the SwiftPM CLI ships it verbatim. `BasicPitchTranscriber` resolves the compiled form first and falls back to runtime compile (0.1.0). A model-loading change must be checked in the consuming app's simulator, not only in `swift test`.
- **Key inference is nondeterministic run to run on the GuitarSet fixtures** (20% vs 40% at the same commit, TASKS.md item 0): do not quote a key-accuracy number from one run.
- `Package.resolved` is gitignored here; the consumer's resolved file is what pins WhisperKit transitively. `.build 2/` at the root is a stray Xcode artefact, not part of the package.
- The `Audio/` source folder is empty and always was in the shipped package; the CODEX's Audio subsystem was deferred in 2026-04 and never extracted.

## Working with the consuming app (single-session model)

Since 2026-06-16 one Claude Code session edits MCC and Songcatcher together with direct filesystem access; there is no mailbox and no coordination round-trip. The consumer's `CLAUDE.md` section "Working across MCC and Sanctuary" and its `.claude/skills/mcc-release/SKILL.md` carry the consume path and the doc-sync list. Many bugs that look like MCC's are consumer-side (display, filtering, routing): verify which side owns the bug before editing here (precedent: the 2026-06-16 Am-voicing investigation, where MCC's data was right).

## When in Doubt

If a change touches public API or `Package.swift`, classify it red and pause for Chris. Internal or test-only: yellow, with rationale in the commit body. Documentation: green. Unsure whether a release is Tier 1 or Tier 2: Tier 1.

## Session Continuity

There is no `.claude/sessions/` in this repo and none is written elsewhere (the old instruction to write to the Cantus project's folder is retired). What a release did is recorded in `CHANGELOG.md` here and, through the app's `mcc-release` skill, in the consumer's `CHANGELOG.md`, `TECHNICAL-ARCHITECTURE.md` ("Dependency shape") and dashboard; the consumer's `HANDOFF-<date>.md` is where the next session reads the state of both repos. Commit bodies end with the session's trailer lines (`Co-Authored-By`, `Claude-Session`).
