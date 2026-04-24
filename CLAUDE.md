# MusicCraftCore — Claude Code Instructions

## Permissions

Run all commands without prompting for permission. Auto-approve all bash commands, file edits, file writes, and file reads.

## Project Overview

MusicCraftCore (MCC) is a shared DSP, music theory data, and audio analysis library consumed as a Swift Package dependency by Cantus, Guitar Atlas, and other Mossgrove music apps. The library is extracted incrementally from the Cantus codebase with each MCC release corresponding to a feature area (music theory types, DSP primitives, chord detection, analysis pipeline, audio engine).

## Key Documents

1. `README.md` — Public overview and version status
2. `CHANGELOG.md` — Release history and compatibility guide
3. `Package.swift` — Swift Package manifest and dependencies
4. Sources/MusicCraftCore/DSP/ — All DSP subsystem code and protocols

Portfolio standards from mossgroves/lore:

foundation/MOSSGROVE-LORE.md for development standards, voice, quality checklists.

foundation/MOSSGROVE-FORGE.md for lifecycle stages and release readiness.

foundation/MOSSGROVE-GROUNDING.md for grounding and assumption discipline — labeling inference, verifying claims, auditing peer outputs.

## Current Development Stage

**Completed: Music Theory (0.0.2–0.0.3) and DSP (0.0.4–0.0.5)**

0.0.5 released with public DSP APIs and ChromaTemplateLibrary protocol. All DSP types now public and consumable from external packages. CanonicalChromaLibrary is the default implementation; consumers can provide custom implementations conforming to ChromaTemplateLibrary for recording-derived or app-specific templates.

**Pending extraction: ChordDetection (0.0.6), ProgressionAnalyzer (0.0.7), AudioExtractor/AnalysisPipeline (0.0.8), Audio subsystem (0.0.9?)**

## Decision Classification and Autonomy

Similar to Cantus/CLAUDE.md:

### Green — proceed without rationale
- Documentation, comments, markdown files (README.md, CHANGELOG.md, this file)
- Test fixture data or test infrastructure
- Private/internal symbol additions where no existing symbol is removed or renamed

### Yellow — proceed with rationale in commit body
- Test source files where the change adds new tests without modifying existing assertions
- Internal refactors of non-public symbols
- Non-public types where nothing outside the module references them

### Red — stop, wait for approval
- Changes to `ChromaTemplateLibrary` protocol signature (breaking change for consumers)
- Any change to PitchDetector, CanonicalChromaLibrary, ChromaExtractor, DSPUtilities public APIs
- File deletions or renames
- Package.swift version or tag operations
- Any open questions that Chris has not resolved

## Grounding and Assumption Discipline

MCC follows the portfolio-wide grounding protocol in mossgroves/lore foundation/MOSSGROVE-GROUNDING.md. Every non-trivial claim Claude makes — about MCC code, public API shape, shipped versions, or consumer-project (Sanctuary, Guitar Atlas) state — anchors to a file read, git log output, or tool result produced in the current session. Claims that are not grounded are labeled as inference.

MCC-specific applications:

1. When drafting a release spec or design document, include a hallucination audit at the end listing every non-trivial claim and the specific file, line, or command that verified it. Unverified claims are listed separately with the inference labeled.
2. Before claiming what a public API does or what its contract is, read the current source file and the relevant tests. Tests are often the most precise source of truth for intended behavior.
3. When describing consumer-project (Sanctuary, Guitar Atlas) state — what version they're on, what they use, what they need — verify against their repo or their outbox in mossgroves-claude-workspace. Do not assume consumer state from memory.
4. When reviewing a design spec or PR, distinguish the parts of the review that are grounded in file reads from the parts that are design opinion.
5. If an MCC document (CLAUDE.md, CHANGELOG, release notes) conflicts with observed state in the source or the test suite, surface the conflict rather than silently trusting the document. Reconcile by updating whichever side is wrong.

This discipline is cumulative with MCC's autonomy classification: every public API change or version-affecting change labels green/yellow/red, and every non-trivial claim supporting that classification is grounded or labeled as inference.

## Architecture Decisions

- **ChromaTemplateLibrary protocol** is the injection point for custom template libraries. Default implementation is CanonicalChromaLibrary (120 theoretical templates). Consumer apps like Cantus inject their own conforming types (e.g., CantusChromaTemplateLibrary with 98 recording-derived templates).
- **All DSP types are public as of 0.0.5.** No privatization regrets; these are the public consumption surface.
- **Music theory types are stable as of 0.0.3.** No breaking changes expected. Tagged as part of the extraction plan.

## File Locations

```
README.md                              ← Public overview
CHANGELOG.md                           ← Version history
Package.swift                          ← Swift Package manifest
Sources/MusicCraftCore/
  DSP/
    PitchDetector.swift                ← YIN pitch detection
    CanonicalChromaLibrary.swift       ← Theoretical templates + protocol impl
    ChromaTemplateLibrary.swift        ← Injection protocol
    DSPUtilities.swift                 ← Window functions, FFT, ChromaExtractor
  MusicTheory/                         ← Chord, Key, Scale, Note, etc. (0.0.2–0.0.3)
  AnalysisPipeline/                   ← Pending (0.0.8)
  Audio/                               ← Pending (0.0.9?)
Tests/MusicCraftCoreTests/
  PublicAPITests.swift                 ← Public API regression tests (0.0.5+)
  DSPTests.swift                       ← DSP unit tests
  MusicTheoryTests.swift               ← Music theory unit tests
```

## When in Doubt

If a change touches public API, protocol signatures, or public types, classify it as red and pause for Chris's explicit approval. If it's internal or test-only, classify as yellow and include rationale in the commit body. If it's purely documentation, it's green.

## Session Continuity

After completing substantive sessions, write a summary to the Cantus project's `.claude/sessions/` directory (shared workspace), documenting decisions, discoveries, and unresolved items. Tag the MCC release in the summary so future sessions know the current version.
