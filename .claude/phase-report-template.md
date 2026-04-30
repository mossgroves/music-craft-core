# Phase Report Template

Canonical structure for phase completion reports across Mossgrove projects. The Verification section is required, not optional. If it cannot be filled honestly, the phase is not complete.

Each project repo also has this template at `.claude/phase-report-template.md` for proximity to the work; the Lore copy is the source of truth.

## Summary

One paragraph: what shipped, what was measured (or explicitly deferred), what stays incomplete.

## Deliverables

Bulleted list of files created/modified, commits with hashes, push status.

## Measurements (if applicable)

For measurement phases: per-target numbers, threshold comparison per the 15-point literature rule, whether thresholds passed or surfaced findings. For implementation phases: what runs end-to-end and what input it ran against.

## Verification

- **Target input:** what was actually fed in (real data, stub, skipped, etc.)
- **Measurement output:** numbers, not "tests pass"
- **Falsification test:** what would prove this completion claim wrong
- **Shared-signal changes:** any edit to cross-project log, BACKLOG, allowlist, outbox, with source-code change that justifies it. If no source-code change, the edit is suspect.

## Next

The actual next step (specific phase, device test session, deferred item). Not "Phase X next" without saying what triggers Phase X.
