# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.16] - 2026-08-26

### Fixed — the Basic Pitch note decode was quadratic in the take length; it is now near-linear, with identical output

2026-08-26, Chris's 13:48 take: a 13.8-minute recording was "still listening" after 15+ minutes
on the phone. Measured on the Mac (`tools/take-probe`, release): a 72 s take decoded in 1.1 s but
the 828 s take (3774 notes, 665 chord segments) took 95 s; `sample` put 6062 of 6062 samples in
`BasicPitchDecoder.argmax2D`. The phone runs Debug from Xcode, where the same take extrapolated
to about 40 minutes.

The cause is structural in the upstream algorithm this port follows (`output_to_notes_polyphonic`,
spotify/basic-pitch @ fa5997af): the "melodia trick" takes `np.argmax` over the WHOLE remaining-
energy grid (F frames x 88 pitches) once per candidate, and the candidate count K grows with F, so
the decode is O(K · F · P), quadratic in duration.

The fix keeps the reference's greedy order and tie-breaking exactly (lowest frame, then lowest
pitch, on equal energy) but finds each argmax from an index instead of a rescan:
`BasicPitchDecoder.FrameMaxIndex` holds a per-frame maximum (value + first pitch) and a segment
tree over frames whose root is the first frame holding the grid maximum. A candidate now costs
O(log F) to find and O(extent · P) to retire (only the frames it zeroed are re-indexed, and only
when the zeroed band contained the frame's argmax pitch, which is provably the only case where
the frame's maximum can change). Memory is O(F), never an entry per cell. Public API unchanged.

Byte-identity, 18 takes (the 17-take Sanctuary corpus plus the 828 s take), release, pre-edit
source vs fixed source: `detectedNotes` byte-identical on all 18 in every run. `chordSegments`
and everything downstream are byte-identical on all 18 once both binaries run with
`SWIFT_DETERMINISTIC_HASHING=1`; with default hashing the SAME binary differs from itself run to
run in the last ULP of chord confidences (17 of 18 takes, and one take flips 36/38 segments), a
pre-existing Dictionary-order nondeterminism downstream of the notes (`ProgressionAnalyzer.inferKey`
ties, already noted in TASKS.md and `ChordSequenceDecoder`), not a property of this change.

Timing (Mac, release, `take-probe` pitch-only, extract seconds):

| take | length | before | after |
|---|---|---|---|
| a recording 2 (the 13:48 take) | 828 s | 98.4 s | 3.5 s (28x) |
| You Make My Heart Sing mix3 | 308 s | 18.3 s | 1.5 s |
| 6 Human | 279 s | 13.6 s | 2.1 s |
| 1 Forever | 248 s | 13.1 s | 3.3 s |
| Love is on the Rise 2026-08-12 | 72 s | 1.13 s | 0.54 s |

Debug (what the phone runs from Xcode; Mac, `take-probe` debug build, extract seconds): the 72 s
take 27.5 s → 3.6 s; the 828 s take 42 s after, against pre-edit debug runs of the same file
that took roughly an hour of CPU each (the app's "still listening for 15+ minutes").

Tests: `BasicPitchTranscriberTests` gains three pure tests that pin the indexed decode to the
pre-0.1.16 full-grid scan (kept under `DEBUG` as `outputToNotesReferenceScan`) on grids with
deliberate float ties and on quantised random grids, plus a direct tie-break test of
`FrameMaxIndex`. 504 tests, 22 skipped, the same two allowlisted GuitarSet failures as before.

## [0.1.15] - 2026-08-17

### Fixed — the Apple transcription fallback is pinned on-device

`LyricsExtractor`'s Apple-path fallback now requests on-device recognition explicitly, so the
songwriter's audio never leaves the device on that path either (Sanctuary's privacy promise P2).
Recorded here after the fact: the tag shipped without a changelog entry.

## [0.1.14] - 2026-08-13

### Fixed — the relative minor no longer steals the major: a minor call must hold its own bass

Relative-minor-for-major substitution was the dominant error class on the 2026-08-13 Rodanthe
scoring (capo-2 fingerpicked take, scored against the song's own sheet, shapes transposed to
sounding): **7 of 8 wrong chords and all 5 transition blips** renamed a major to its relative
minor — A heard as F♯m(7), D as Bm(7) — always in-key, always on short segments at transitions,
while every sustained chord scored 5/5. Confidence cannot filter it (wrong calls averaged 0.75
vs 0.78 for right ones; one wrong call sat at 0.96).

The mechanism (per-window evidence sweep): a transition window BLENDS two adjacent majors, and
the relative minor 7 is the four-note candidate that covers the blend best — F♯m7 = the whole A
triad plus D's F♯ — so it outscores either honest major on coverage alone, at honestly high
confidence. What separated every wrong call from every real minor across the corpus was the
**bass**: a real short minor holds its root under the chord for about a beat; an artifact never
does (≤1 window, usually 0). The weight-ratio alternative failed on the same data — wrong runs
reached a 0.87 minor-root/relative-root ratio while Kill Devil Hills' real F♯m7 sat at 0.28.

The fix is `AudioExtractor.relativeMinorGuarded`, run-level like the 0.1.7 bare-dyad guard: a
short (≤3-window) minor/minor7 run whose root never holds the detected bass for ≥2 windows is
renamed to its relative major — but ONLY when the major earns the name, either by the full
relative-major triad sounding in the run's summed windows WITH the relative-major root touching
the bass, or by an adjacent run rooted on the relative major whose tones cover everything the
run sounded beyond its claimed root. No evidence → no rename: Romance de Amor's Em→Am boundary
keeps its honest Am7 rather than gaining a C the piece never plays. Sole runs and sustained
minors are structurally exempt.

Measured (Mac, release, `take-probe` over the Sanctuary corpus, 2026-08-13):

| take | before | after |
|---|---|---|
| Rodanthe 2026-08-13 | 12 wrong-root events of 46 (73.9%) | **1 of 38 (97.4%)** — all 11 substituted minor segments gone, each resolving to the sheet's sounding D/G/A |
| Kill Devil Hills | three 0.5 s F♯m7 ring-over blips; key B minor | blips absorb into the sheet's A; real Bm runs and both bass-holding F♯m7s kept; key **D major** — the sheet's C-shape tonic at capo 2 |
| Romance de Amor | — | byte-identical: Am7 (0.64) and B7 (0.39) survive |
| Broken Man | ten 0.5 s Gm(7) ring-over blips (G is A♯'s 6th) | absorbed into the adjacent A♯; bass-supported Gm7s at 9.0/51.0 s kept, three more kept for want of rename evidence; key C minor unchanged |
| Instrumental in D | 0.31-confidence Bm7 inside the D drone | absorbed; sustained Bm7 sections kept |

GADA / TaylorNylon single-chord benches unchanged (sole runs are never renamed, so the fixtures
are structurally exempt). Eight new `ChordSequenceDecoderTests` pin the rule's keep AND rename
sides, including the Romance boundary and the Bm7-inside-Bm carve-up the first draft of the
cover test would have caused.

## [0.1.13] - 2026-08-12

### Fixed — the seek crawl is CANCELLED, not outlasted: the window cap the token budget wasn't

0.1.12's slicing bounded the decode count ACROSS a take; inside one slice, WhisperKit's seek
loop stayed unbounded, and the 2:00 sparse capture ("recorded at 9:09 PM") found the hole: a
near-silent slice decodes an EMPTY segment whose closing timestamp sits fractions of a second
in, the seek advances only that far, and the slice opens windows forever. Traced on a Mac
(release, pinned config): **345 windows in the first 45 s of ONE slice**, 4 callbacks each,
empty text, mean seek advance under 0.09 s per window — and the token budget spent itself at
~window 80 to no effect, because returning `false` from the progress callback ends only the
current window's token loop; the seek loop is unreachable from the callback.

The fix is `SliceDecodeLedger`: it spends the token budget exactly as before AND counts window
transitions (the progress token count resetting; `<=` not `<`, because post-budget windows emit
one token each and never drop), cancelling the slice's decode `Task` at `maxWindowsPerSlice`
(8 — a healthy slice is 1-2 windows, the crawl is hundreds). Cancellation is the one lever that
reaches the seek loop: WhisperKit 1.1.0 checks `Task.checkCancellation()` there
(`TranscribeTask.swift:135-165`). A wall-clock watchdog (`sliceDecodeWallCap`, 15 s) backs the
heuristic. A cancelled slice contributes nothing — its decode was producing empty segments —
and the take's other slices decode normally, so real singing elsewhere in the take survives.

Measured (Mac, release, `take-probe` over the Sanctuary corpus, 2026-08-12):

| take | before | after |
|---|---|---|
| "a recording" (the 2:00 sparse capture) | never completed (>8 min, killed) | **5.1 s wall, 60 real sung tokens** |
| Broken Man / Sweet Mystery 2026-08-11 / Kill Devil Hills 2026-08-12 / Instrumental in D 2026-08-12 | — | tokens byte-identical to pre-fix |

`WhisperLyricsEngineTests`: 35 executed / 0 failures, including five new `SliceDecodeLedger`
tests (window counting, single-fire breach, the install-race, budget verdict, healthy-slice
immunity).

## [0.1.12] - 2026-08-12

Retro-recorded 2026-08-12 (the release shipped as commit `e6c2d94` and Sanctuary's
`Package.resolved` consumed it as 0.1.12; the tag and this entry were created after the fact).
**The Whisper pass**: decode bounded by construction — fallback ladder off
(`temperatureFallbackCount 0`), 30 s-sliced decode with a per-slice token budget, `sampleLength`
160. The 2:00 sparse take that ground 372 s on device: 3.9 s. The **coverage gate** refuses
sparse-and-weak transcripts whole (≥30 s, <25 wpm AND mean conf <0.50) and an empty Whisper
result consults the Apple path. `transcriptionLanguage` plumbed (default "en"; nil = detection,
not yet flipped anywhere). Full record: Sanctuary `HANDOFF-2026-08-12.md` and the 0.1.12 pin
comment in Sanctuary's `project.yml`.

## [0.1.11] - 2026-08-10

Retro-recorded 2026-08-12 (shipped as commit `7560780`; tag and entry created after the fact).
`TranscribedToken.startsSegment` — the recognizer's own segment boundaries survive the
flattening into one token stream, giving Sanctuary's line-break menu the phrasing signal
silence cannot provide on sung takes. Full record: the 0.1.11 pin comment in Sanctuary's
`project.yml`.

## [0.1.10] - 2026-08-10

Retro-recorded 2026-08-12 (shipped as commit `98f0791`; tag and entry created after the fact —
"Chris authorized the tag and push" is recorded in the pin comment; the tag step was missed).
The take's OPENING WORD is exempt from the ghost-confidence floor: Whisper under-scores a
take's first word (measured 0.06-0.48, median 0.215, vs corpus median 0.98) for reasons
unrelated to whether it was sung, and two of six real openings fell under a floor drawn
against hallucinations. Exactly one token is exempt; the floor is otherwise unchanged. Full
record: the 0.1.10 pin comment in Sanctuary's `project.yml`.

## [0.1.9] - 2026-08-09

### Added — `LyricsExtractor.prepare(configuration:)`: warm the Whisper engine before it is needed

A consumer can now load the Whisper Core ML pipeline WITHOUT transcribing anything, so the first real
transcription of a process pays for decoding alone. Additive; no existing signature changes and no
decode behavior changes.

**The report this answers.** Chris, on device 2026-08-09: *"I turned on the setting for Geo Location
data and ran a quick test just a six second recording and the analysis took over 20 seconds."* Model
load is a FIXED cost — it does not shrink with the audio — so on a six-second take it is not part of
the analysis time, it IS the analysis time.

**Measured, this Mac (Apple Silicon, ANE), `openai_whisper-small`, a real 6-second sung slice:**

| stage | cost |
|---|---|
| first-ever load for a given client binary | **28.1 s** (Core ML specializing for the neural engine) |
| every later load, fresh process | **0.57 s** |
| decode of the 6-second clip | **0.21 s** |

The specialization result is cached by the OS and keyed to the client, not just to the model: a second
binary loading the same folder pays it again (measured — the xctest bundle's first `preload` cost
24.9 s, its next two 1.0 s and 0.9 s). The device figure for that first load is 22 s (iPhone 17 Pro
Max, Sanctuary BACKLOG "Lyric transcription", 2026-08-07).

- **`LyricsExtractor.prepare(configuration:)`** — no-op when `whisperModelFolder` is nil, idempotent,
  and FAIL-SOFT like the read path: a folder that cannot load is swallowed, because warming must never
  become a new way for an app to learn about a problem it would otherwise route around.
- **`WhisperLyricsEngine.preload(modelFolder:)`** (internal) — the same work, but it THROWS, so a
  caller that wants to know can ask. That is what keeps `prepare`'s silence a policy and not a gap.
- **WHEN to warm stays the app's decision.** MCC cannot know when a songwriter is about to sing, and
  warming holds the models resident (measured peak footprint 139-160 MB), so warming at launch and
  never recording is memory paid for nothing.

### Fixed — the pipeline was loaded TWICE on every process's first transcription

`PipelineStore` built its `WhisperKitConfig` with `prewarm: true` AND `load: true`, under a comment
claiming prewarm gave "sequential per-model CoreML specialization [that] keeps peak load memory down
(one model in memory at a time)". Reading upstream (WhisperKit 1.1.0 `Models.swift:24`,
`WhisperKit.swift:360-437`) shows that is not what the flag does: `prewarmModels()` is
`loadModels(prewarmMode: true)`, and in prewarm mode each loaded model is immediately DISCARDED
(`model = prewarmMode ? nil : loadedModel`). With `load: true` also set, the same three `MLModel.load`
calls simply ran a second time. It staged nothing — peak memory is set by the real load pass, which
retains all three either way.

Now `prewarm: false`. Measured with the specialization cache warm: **0.850 s → 0.572 s** for
byte-identical loaded models. Decode behavior is untouched; the pinned decode config, the artifact
filter and the Apple fallback are all unchanged, so the measured WER of the 2026-08-07 six-song
validation still stands.

### Documented — the pipeline cache survives across analyses, measured rather than asserted

`PipelineStore`'s doc now carries the measurement instead of the claim: three consecutive
`LyricsExtractor.transcribe` calls on one 6-second clip in one process, each with a freshly
constructed `Configuration` (mirroring a consumer that builds a new analyzer per capture), cost
**1.207 s, 0.238 s, 0.225 s**. Only the first pays the load, and nothing a consumer does at its own
layer can defeat that — the store hangs off a module-level `static let` and is keyed by folder path,
not held by the caller. What it cannot survive is process death, which is what `prepare` is for.

## [0.1.8] - 2026-08-08

### Added — the vocal-stem side-channel: the melodic contour traced from the separated voice

On a recording that contains singing, the melody can now be traced from an ISOLATED VOCAL SIGNAL
instead of from the full mix. That is the whole feature. It exists because a contour traced from a mix
is not a melody: measured on "6 Human" (2026-08-08), the mix yields 1190 note events at 4.27/s with 11%
stepwise motion — the signature of noise; the isolated voice yields 394 at 1.41/s with 54% stepwise
motion — a singable line. Chris listened to the rendered stems and approved on 2026-08-08.

- **`Voice/VocalIsolator` (new public type).** Offline-renders a mono or stereo non-interleaved Float32
  buffer through Apple's **AUSoundIsolation** AudioUnit (`aufx`/`vois`/`appl`, reported as
  "Apple: AUSoundIsolation" 1.6.0) in `AVAudioEngine.manualRenderingMode(.offline)`, fully wet,
  isolating voice. Two entry points — `isolateVoice(_:sampleRate:) -> [Float]` (mono, the shape
  `AudioExtractor` consumes) and `isolateVoice(_:) -> AVAudioPCMBuffer` (mono or stereo) — plus an
  `isAvailable` component probe. Ported from the on-device-validated `StemProbe.swift` harness:
  - **`AVAudioUnit.instantiate`, never `AVAudioUnitEffect.init`** — the former hands back an `Error`,
    the latter raises an uncatchable ObjC exception. Every failure path throws a typed
    `VocalIsolator.Failure`; nothing traps.
  - **`kAudioUnitProperty_SupportedNumChannels` is checked BEFORE connecting**, because
    `AVAudioEngine.connect` also raises an uncatchable exception on a layout the AU refuses.
  - **Parameters are set before engine initialization and then VERIFIED BY READ-BACK.**
    `WetDryMixPercent` 100 and `SoundToIsolate` = `HighQualityVoice`. The read-back is required, not
    defensive: the parameter's historical declared range was 1...1, so a write of 0 can be silently
    CLAMPED rather than rejected. `HighQualityVoice` is `macos(15.0)`/`ios(18.0)` — below MCC's floors —
    so it is requested behind `#available` with a runtime fallback to the standard `_Voice` model.
  - **Latency compensation from the AU's own report**, never hardcoded: `kAudioUnitProperty_Latency`
    (measured 6360 frames at 48 kHz stereo, 4440 mono) is trimmed off the head so derived timings stay
    aligned with the recording. The arithmetic is factored into pure, unit-tested helpers
    (`headTrimFrames` / `totalFramesToRender` / `headTrimSplit`).
  - **Output can exceed full scale** (measured peak 1.12) and is deliberately neither normalized nor
    clipped; the silence guard downstream is a floor, never a ceiling.
  - `Task.isCancelled` is checked per render block, so an expiring BGProcessingTask stops the render
    promptly instead of finishing it.
- **`AudioExtractor.Configuration.ContourSource` + an `isolatedVoice:` overload (both additive).**
  `contourSource` defaults to `.mix`, so **existing callers are byte-identical in behavior**; the new
  field is appended last on the memberwise initializer, so the pre-0.1.8 nine-argument call still
  compiles. `.isolatedVoice` asks MCC to run `VocalIsolator` itself and transcribe the result in a
  second Basic Pitch pass; the `extract(buffer:sampleRate:configuration:isolatedVoice:)` overload takes
  an already-isolated buffer instead. **MCC owns the isolation** (MCC owns DSP, and the AU is
  `macos(13.0)`/`ios(16.0)`, below MCC's macOS 14 / iOS 17 floors, so it always links); the overload
  exists for apps that already hold a stem or must own the AudioUnit's thread context.
- **ONLY the contour reads the stem.** `chordSegments`, `key`, `detectedNotes`, `voicingDensity` and
  `duration` all still derive from the single mix pass, untouched — as does tempo, which consumers
  estimate from `detectedNotes`. The measured reasons: the stem reads `voicingDensity` 1.09 on a take
  whose mix reads 2.50, which would misclassify a full-band take as a hum and cascade through every
  consumer gate; and lyric transcription measured WORSE on stems (23.9% WER vs 16.7-22.8% on the mix)
  because separation damages consonants. A unit test asserts field-by-field that supplying a voice
  buffer moves the contour and nothing else.
- **Gating on voice is the CONSUMER's call, deliberately.** Isolation must never run on an
  instrument-only take: measured, it leaves sparse transient residue peaking at -5 dBFS that a pitch
  tracker reads as plausible phantom notes that were never sung. The decision comes from MIX-derived
  signals (the app's take-type routing: `voicingDensity` plus transcript presence, the latter of which
  MCC cannot see). MCC does not invent a second threshold, for the same reason `voicingDensity` ships
  as a number and not a verdict.
- **The plausibility guard (`AudioExtractor.isPlausibleStemContour`, pure and unit-tested).** A
  stem-derived contour that is empty, or thinner than `minimumStemContourNoteRate` = **0.25 note
  events per second of take**, is discarded and the mix-derived contour is kept.
  **The threshold is PROVISIONAL pending device tuning.** It is anchored to the single measured pair
  above (1.41/s sung vs 4.27/s mix) and sits at a fifth of the sung rate — deliberately far below it,
  because the guard's job is to catch a separation that produced NOTHING, not to adjudicate musical
  density. One held note per four seconds still passes. A density CEILING is deliberately absent: a
  fast melisma is also dense and no measurement yet separates it from noise.
- **Fail soft, always.** Component missing, instantiation error, refused layout, render failure,
  cancellation, an empty or near-silent stem, or an implausible contour — every one of them falls back
  to exactly today's behavior (contour from the mix) with no user-visible error. The stem is
  transient: it is never cached, stored, synced, or written anywhere, so storage growth is zero.
- Tests: **+51** (409 → 460 executed). `VocalIsolatorTests` (+24, AU-free) covers the latency-trim
  arithmetic against the measured 6360/4440-frame values, frame-count conservation across a whole
  render, channel-support wildcards, and every failure reachable without the AU;
  `AudioExtractorContourSourceTests` (+22) covers the plausibility guard, contour selection, the
  configuration surface, and API routing on real bundled fixtures (including the field-by-field proof
  that only the contour changes); `PublicAPITests` (+2) pins the new public surface per the Tier 2
  rule; `VocalIsolatorIntegrationTests` (+3) is environment-gated and skips by default (18 → 21
  skipped). `musicCraftCoreVersion` → "0.1.8". Full suite: **460 executed, 21 skipped, 3 failures** —
  the same 3 long-documented GuitarSet expected-failures in the same two test cases, no new ones
  (baseline re-measured on pristine HEAD in the same session: 409 executed, 18 skipped, 3 failures,
  identical failure set).
- **Real-render proof (environment-gated `VocalIsolatorIntegrationTests`, 3 tests, RUN LOCALLY
  2026-08-08 on "6 Human.wav").** Gated behind `MCC_ISOLATION_AUDIO_FILE` (plus optional
  `MCC_ISOLATION_INSTRUMENTAL_END`, default 10 s) so the normal suite stays AU-free. The AU ships on
  macOS too, so this runs on the development Mac. The test that matters is the energy check: a
  pass-through would show no difference, but the stem must lose far more energy in a region where
  nobody is singing than it loses over the take as a whole. "6 Human" has its first sung word at 13.84 s
  (WhisperBench transcript, 2026-08-07), so its first 10 s is genuinely instrumental.

  | path | frames in → out | speed | stem/source RMS, whole | stem/source RMS, instrumental | stem peak |
  | --- | --- | --- | --- | --- | --- |
  | stereo, buffer API | 13382400 → 13382400 | 28x realtime | 0.5377 | 0.0881 | 1.1191 |
  | mono, sample-array API | 13382400 → 13382400 | 66x realtime | 0.6583 | 0.0480 | 1.1876 |

  The stereo row reproduces the 2026-08-08 on-device measurement almost exactly (device: 0.5378 whole,
  0.0885 instrumental, peak 1.1220) — independent corroboration that this port renders what the probe
  rendered. Equal in-and-out frame counts are the latency compensation working. The third test drives
  the whole feature through `AudioExtractor` on a 45 s window of the same file (bounded because Basic
  Pitch is slow in an unoptimized test build) and reproduces the finding the feature exists for: mix
  contour **158 events at 3.51/s**, stem contour **50 events at 1.11/s**, with every mix-derived field
  unchanged.
- **Not done here, on purpose:** no mass re-analysis of existing recordings (they keep their current
  reading until the songwriter listens again, matching how the Whisper engine shipped), and no stem
  caching — a future "hear only your voice" feature would need it and is explicitly out of this scope.

## [0.1.7] - 2026-08-08

### Changed — chord quality on real songs: Viterbi sequence decode + bare-dyad guard + key-aware prior

The three measured chord-detection quality bugs from the 2026-08-07 ceiling analysis of a real song
("6 Human", an A-minor loop; Sanctuary BACKLOG chord/ceiling evidence): (a) Am↔A / Em↔E quality
flips — sung melody notes contaminate the per-window pitch-class histogram and the major/minor
decision reduces to third-vs-third weight; (b) chord-per-word churn — every 0.5 s-hop window was
labeled independently, so one contaminated window became its own segment (and `cleanupRuns`' flicker
rule requires identical flanks, so "Am A Em G" survived); (c) phantom standalone E/A majors — a bare
fifth dyad deterministically named MAJOR (candidate ordering + strictly-greater replacement).

- **Viterbi sequence decode (new internal `ChordDetection/ChordSequenceDecoder`).**
  `noteNativeChordSegments` no longer takes a per-window argmax: each window's FULL candidate score
  vector (new additive API `NoteChordIdentifier.candidateScores` — 12 roots × 9 qualities = 108
  candidates, plus public `candidateQualities` / `candidateCount` / `candidate(at:)` to interpret it)
  is decoded as a SEQUENCE with a self-transition-favoring switch penalty (one tunable, 0.12 — the
  literature's single biggest documented chord lever, Cho & Bello-class ≈+22 points). A momentary
  contamination is absorbed into its neighbors' label; a sustained real change accumulates margin and
  always wins. Windows with no usable content stay nil and split the decode (no continuity invented
  across silence). Neutral by construction on single-chord material — when every window argmaxes the
  same candidate the decode changes nothing.
- **Bare-dyad guard (`AudioExtractor.bareDyadGuarded`).** A decoded major/minor run whose windows
  never sound EITHER third is a bare root+fifth dyad wearing a deterministic default (major sorts
  first in `candidateQualities`; replacement is strictly-greater), so it is renamed to the `.power`
  naming — "E5", not "E". Kills the phantom standalone E/A majors. Two deliberate limits, both
  evidence-driven:
  - **It never touches a SOLE run** — the same posture `cleanupRuns` already takes. Measured
    2026-08-08 on the labeled bench: four of the nineteen sustained TaylorNylon G takes
    (G_015–G_018) transcribe as a pure D+G dyad with NO B in any window, because Basic Pitch misses
    the third on nylon strings with weak 3rd harmonics and sparse fingerpicked voicings. Ground
    truth on all four is G major, so an unconditional guard names them "G5" and costs 3.7 points of
    bench exact accuracy (99.1% → 95.4%). With one chord and no context, a missing third is more
    likely a transcription miss; among OTHER chords — the phantom's actual shape — the dyad reading
    is the honest one.
  - **`NoteChordIdentifier.identify` is UNCHANGED** and keeps naming a bare dyad by candidate
    ordering. A single histogram carries no context to make this call with, which is precisely what
    the four G takes demonstrate; the veto belongs at the run level or nowhere.
  A dyad window the decode absorbed INTO a flanking chord's run never reaches the guard as its own
  run — context already named it, which is the guard's other honest outcome.
- **Key-aware second decode pass.** Once the decoded progression itself supports a key (chord-based
  `ProgressionAnalyzer.inferKey` over ≥2 distinct chords — a melody-fallback key is not evidence
  enough to re-bias chord naming), the windows are re-decoded with a small non-diatonic penalty
  (0.08, the same magnitude class as the existing qualityPriors). The harmonic-minor V (E / E7 in
  A minor) is scored quasi-diatonic so a REAL harmonic-minor E survives, while an artifact A-major
  inside A minor now needs genuine C♯ evidence. Single-chord fixtures are structurally exempt (no
  progression → no second pass).
- **Decision noted:** the generalized short-run absorption considered for 9.4 (BACKLOG "residual
  follow-on") stays OUT — the Viterbi decode is the principled version of it and supersedes it. The
  shipped conservative 0.1.1 `cleanupRuns` passes (edge trim + identical-flank flicker absorb) still
  run on the decoder's output.
- Tests: +24. `ChordSequenceDecoderTests` (+22) covers decode absorption / neutrality /
  genuine-change / loop / nil-split, the run-level dyad guard incl. sub-floor third,
  one-third-bearing-window, non-triad runs and the sole-run exemption, and the key-prior asymmetry
  incl. harmonic-minor V; `PublicAPITests` (+2) pins the new public candidate-space surface per the
  Tier 2 release rule. Existing `NoteChordIdentifierTests` unchanged and green; `RealAudioChordTests`
  thresholds unchanged and green. `musicCraftCoreVersion` → "0.1.7". Full suite: 409 executed,
  18 skipped, 3 failures — the same 3 long-documented GuitarSet expected-failures, no new ones.
- **Regression evidence (2026-08-08, measured against a pristine-HEAD worktree run of the same
  fixtures on the same machine).** The labeled single-chord benches are byte-identical either side of
  this change, on BOTH of the bench's two views:

  | fixture | HEAD root/exact | 0.1.7 root/exact | confusions |
  | --- | --- | --- | --- |
  | GADA (32), integrated | 100.0 / 100.0 | 100.0 / 100.0 | none |
  | GADA (32), note-native direct | 100.0 / 100.0 | 100.0 / 100.0 | none |
  | TaylorNylon (109), integrated | 99.1 / 99.1 | 99.1 / 99.1 | C→A ×1 (both) |
  | TaylorNylon (109), note-native direct | 99.1 / 99.1 | 99.1 / 99.1 | C→A ×1 (both) |

  On the multi-chord GuitarSet set — the material this arc is actually for — progression mean CSR
  moved 28.7% → 31.5% (deterministic: bit-identical across 6 working-tree runs and 3 HEAD runs). It
  remains under its long-standing 50% threshold and stays a documented expected-failure; the point is
  direction, not a passing gate. The count of expected failures is unchanged at 3.
- **Known, pre-existing: `ProgressionAnalyzer.inferKey` has a nondeterministic tie-break.** Its
  `scores.max(by:)` runs over a Dictionary, and Swift randomizes Dictionary iteration order per
  process, so an exact tie between two candidate keys resolves differently run to run. 0.1.7 doesn't
  introduce this but does expose it: one GuitarSet file's decoded progression now lands on such a tie,
  so `GuitarSetKeyInferenceTests` reports 20.0% or 40.0% exact depending on the run (measured 4×20.0%
  / 3×40.0% over seven runs of identical code; HEAD reports a stable 20.0% only because its chord list
  doesn't tie). No accuracy claim is made for key inference in this release. The fix — a deterministic
  tie-break — belongs to its own change with its own measurement, since it moves key results globally.

## [0.1.6] - 2026-08-07

### Added — WhisperKit sung-lyric transcription path in LyricsExtractor (Apple Speech fallback)
- **`LyricsExtractor.Configuration.whisperModelFolder: URL?`** (default nil) — when the consuming app provides a folder holding a locally-managed WhisperKit CoreML model (validated variant: `openai_whisper-small`), English transcription runs through the new internal **`Voice/WhisperLyricsEngine`** (WhisperKit 1.1.0, new SPM dependency pinned `exact` — MIT); when nil, unloadable, non-English, or on ANY Whisper failure, the existing Apple SpeechAnalyzer / SFSpeechRecognizer path runs **unchanged** as the shipping fallback. Model download/placement/eviction stays app-side; MCC never fetches weights (`download: false`).
- **The decode config is PINNED, measured** (Sanctuary BACKLOG "Lyric transcription", parity check + six-song on-device validation, 2026-08-07): WhisperKit defaults are unshippable on music (92.2% WER — music-bed windows greedy-sample `<|nocaptions|>`); the pinned rescue is `language "en"` + `usePrefillPrompt` + `skipSpecialTokens` + the OpenAI 82-token non-speech suppress list + no_speech `50362` + `firstTokenLogProbThreshold -100` + `wordTimestamps`, and **never any initial prompt** (a title prompt measured a 56.7%-WER repetition catastrophe). Token list copied verbatim from the WhisperBench harness (`BenchModel.nonSpeechSuppressTokens`, commit `73a1a36`).
- **Measured artifact filter** (pure, unit-tested `WhisperLyricsEngine.filterArtifacts`): drops (1) ghost words below word-probability 0.15 (hallucinations over no-vocal regions measured at 0.03-0.19), (2) "Music"-only caption segments (instrumental intros/fades), (3) a trailing lone low-confidence token ending inside the last 30 s decode window (the measured "you"-tail fade-out artifact). Per-word `WordTiming {word, start, end, probability}` maps to `TranscribedToken {text, onsetTime, duration, confidence}`.
- Tests: 13 pure-logic tests (mapping + filter + pinned-config guard) run in every suite pass; one real-inference integration test is gated behind `MCC_WHISPER_MODEL_DIR` / `MCC_WHISPER_AUDIO_FILE` (verified locally on this Mac: 10 s full-mix sung excerpt → 11 correct word tokens, offline model + tokenizer load). `musicCraftCoreVersion` → "0.1.6".

### Added

- **Note-native tempo estimation** — `TempoEstimator.estimateTempo(noteOnsets:)` (2026-07-21). Tempo was the last subsystem still fed by the spectral-flux front-end, whose documented weakness on acoustic guitar (TASKS: all five GuitarSet fixtures locked to 1/3 of ground truth) left consumers with a mostly-abstaining tempo. The new path feeds Basic Pitch's note onsets — the same evidence the note-native chord/key/contour engine already trusts — into the existing TempoHistogram, with strum-cluster collapsing (onsets within 50ms = one gesture) and a `minEvents` abstention floor. **Confidence semantics fixed en route (the dead-axis root cause, measured by test):** the histogram's raw peak-mass share caps ≈0.22 on PERFECT metronomic input, so consumer gates calibrated to the beats path's regularity scale could never pass; the note path reports **IOI consistency** instead (fraction of intervals agreeing with the candidate at 1x/2x/0.5x within ±8%) and ranks candidates by it — steady playing reads ~1.0, rubato reads low, and near-miss/sub-beat peaks the raw histogram can rank first are demoted. +5 tests (steady quarters ≈1.0 confidence, strum-cluster collapse, jittered fingerpicking lands on the beat family, sparse abstains, cluster collapsing).

### Also in this release (committed since 0.1.5; summarized from the commit log)

- **fix(lyrics)** `ed9342e` — chunk `AnalyzerInput`s at 10 s: SpeechAnalyzer fed one giant input only emits the LAST ~150 s (a 4:39 song lost its whole first verse); chunked inputs through one analyzer session transcribe end to end.
- **fix(tempo)** `4627922` — octave disambiguation: the felt tempo beats its double.
- **feat(key)** `e0afaab` — structural re-rank so a I-IV drone reads as I, not the IV (the D-then-G fix).
- **test(metrics)** `a7b1525` — compareKey compares pitch classes, not mismatched strings (true key baseline).
- **feat(voicings)** `cc0a9fc` + **fix** `d55cc6d` — chords-db (MIT) adopted as the guitar-voicing source with inversions + spelling filter; malformed 3rd Am voicing at the 5th position cleaned.

## [0.1.5] - 2026-06-06

### Added — `voicingDensity` on `AudioExtractor.Result` (take-type signal)
- **`AudioExtractor.Result` now carries `voicingDensity: Double`** — the mean number of simultaneously-sounding **distinct pitch classes** over the take's sounding time, computed from the Basic Pitch polyphony (the full note set, not the melodic skyline). **~1.0 for a monophonic/sung take; higher for a polyphonic/played one.** Distinct pitch classes (not raw note count) so octave doublings/overtones don't inflate it. Lets a consumer tell a sung take from a played one — e.g. Songcatcher today misroutes sung takes to "chords heard" because the note-native chord namer names a chord even from a single sung line. **MCC ships the measure; the sung/played threshold is the consumer's policy** (mirrors `KeyCandidate.score` vs `HarmonyKeyGate.minScore`). Internal pure helper `AudioExtractor.voicingDensity(of:)`; `0` for an empty / silence-guarded / model-unavailable result. **Additive** — a new field + a new (non-defaulted) `Result.init` parameter; no behaviour change to existing fields, no new dependency, no third-party integration. Unit-validated + deterministic (new `VoicingDensityTests`); no device gate (the device-validated piece is the consumer's threshold). `musicCraftCoreVersion` → "0.1.5".

## [0.1.4] - 2026-06-01

### Fixed — VoicingLibrary resolves flat-spelled chords (B♭, E♭, A♭)
- **`VoicingLibrary.voicings(for:)` now resolves chords whose bundled spelling is flat** (B♭, E♭, A♭) — previously the lookup only built the sharp-spelled JSON key (A♯, D♯, G♯), which is absent from `guitar_voicings.json` (it stores those roots as Bb/Eb/Ab), so those chords missed the lookup and returned **no voicing**. The lookup now tries the sharp spelling, then the enharmonic flat spelling, before giving up. Also switched the lookup to the decoded `cachedVoicings` (it was re-decoding the JSON on every call). Sharp-spelled roots (C♯, F♯) are unaffected. New `VoicingLibraryTests.testFlatSpelledChordsResolve`. `musicCraftCoreVersion` → "0.1.4".

## [0.1.3] - 2026-06-01

### Changed — unified enharmonic spelling (one flat/sharp policy across key name, diatonic chords, detected chords)
- **`MusicalKey.prefersFlats` is now the single source of truth** for whether a key is spelled with flats (major: F, B♭, E♭, A♭, D♭; minor: Dm, Gm, Cm, Fm, B♭m, E♭m) or sharps. The policy previously lived privately in `DiatonicChordGenerator.keyUsesFlats`; that method now **delegates** to `prefersFlats` (no second copy of the table), so the diatonic output (`generate(for:)` chord names, romans, triads) is byte-identical and its existing tests pass unchanged.
- **`MusicalKey.displayName` now spells flat keys with flats.** It used `root.displayName` (sharp-only), so a C♯/D♭-major key labelled "C♯ major"; it now returns "D♭ major" (and "B♭ minor", etc.) while sharp/natural keys ("A major", "F♯ minor", "E major") are unchanged. `DiatonicChordGenerator.keyDisplayName(for:)` delegates to `MusicalKey.displayName` (one key-name path; they already agreed for every key root via `spelledRoot`, now covered by a test).
- **Added `Chord.displayName(in: MusicalKey)`** — a key-aware chord name that spells the root with the key's preferred accidental (a detected C♯ / A♯m / G♯ renders "D♭" / "B♭m" / "A♭" in D♭ major). The key-blind `Chord.displayName` is **unchanged** (sharp-spelled no-key fallback; existing callers/tests use it).
- **Why:** on-device a single take showed three accidental systems at once — key tonic "C♯", diatonic D♭·A♭, detected C♯·A♯m·G♯. Consumers can now render the key name, the diatonic suggestions, and the detected chords through one policy. New tests cover `prefersFlats`, the enharmonic `displayName`, `displayName(in:)` for flat and sharp keys, and `keyDisplayName == displayName`. No audio-detection or key-inference behavior changed. `musicCraftCoreVersion` → "0.1.3".

## [0.1.2] - 2026-06-01

### Added — iOS 26 SpeechAnalyzer transcription path in LyricsExtractor (SFSpeechRecognizer fallback)
- **`LyricsExtractor.transcribe` now routes by OS.** On **iOS 26+** it uses Apple's modern `SpeechAnalyzer` + `SpeechTranscriber`: per-word tokens whose onset/duration come from the time-indexed `audioTimeRange` (`CMTimeRange`) attribute, with optional per-token confidence (`transcriptionConfidence`, `Double`) when `Configuration.includeConfidence`. The on-device language-model asset is installed on demand (`AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()`); the mono Float32 buffer is converted to `SpeechAnalyzer.bestAvailableAudioFormat` and streamed as `AnalyzerInput`. On **iOS 17–25**, and on **any iOS 26 failure** (model asset unavailable, unsupported locale, transcription error), it falls back to the existing **`SFSpeechRecognizer`** path — kept intact as the floor. `transcribe(...)`'s signature is unchanged; `Configuration` (`waitForFinalResult`, `includeConfidence`) is now honored on the iOS 26 path (it was forward-compatible/ignored before). **Device-validated** (near-verbatim on a sung + guitar take; handled the mix well). Internal Voice change only — no public API signature change. `musicCraftCoreVersion` → "0.1.2".

## [0.1.1] - 2026-06-01

### Release — silence guard + note-native chord-segment cleanup (device-validated)
- Both changes below were device-validated on iPhone 15 Pro Max + Taylor 812ce-n (chords/key correct; the phantom-chords-on-silence read gone; leading transients and held-chord flicker reduced). They touch only the internal `AudioExtractor.extract` behavior — `Result`, `Configuration`, and all public types are unchanged. `musicCraftCoreVersion` → "0.1.1".

### Changed — note-native chord segments: trim pick-attack/release transients + absorb same-root sus flicker
- **`noteNativeChordSegments` cleans up the run list before emitting segments.** Two conservative passes: (1) **edge trim** — drop a leading/trailing run that is short (≤ one window-hop, 0.75 s) AND low-confidence (< 0.7), removing the pick-attack/release window that named a spurious chord before the notes settled (e.g. testspanish's leading `E`, testandy's trailing `G♯`); bench fixtures are a single sustained chord (one long run), so they are never edge-trimmed. (2) **flicker absorb** — a single interior run that shares its root with an *identical* chord on both sides becomes that chord (`Am–Asus2–Am → Am`); different flanks or a different root are left alone, so genuine chord changes survive. On the device-test recordings: testspanish 10→7 segments, test 14→12, testandy 21→14 — leading transients gone, held-chord sus flicker collapsed, the multi-chord progressions and inferred keys preserved. The 3-way bench's integrated-`extract` **exact** accuracy rose to match the direct namer (GADA 93.8→100, TaylorNylon 92.7→99.1; root unchanged 100/99.1), because `chordSegments.first` is now the settled chord rather than the attack artifact. No public API change.

### Fixed — near-silence guard: digital silence no longer yields phantom chords/key
- **`AudioExtractor.extract` returns an empty `Result` when the input buffer is essentially silent** (peak amplitude below ~-60 dBFS), short-circuiting before the Basic Pitch model runs. The model decoded an all-zero buffer to ~16 phantom notes + a spurious key; the guard prevents that. The peak floor (`1e-3`) is orders of magnitude below a real quiet nylon capture (the device-test recordings peak at 0.30–0.52, rms ~0.057–0.066), so genuine quiet fingerpicking is never suppressed — verified that testspanish/test/testandy analyze identically with and without the guard. New test `testSilentBufferProducesEmptyResult`. Bench unchanged (GADA 100/93.8, TaylorNylon 99.1/92.7). No public API change.

## [0.1.0] - 2026-06-01

### Removed — the hand-rolled DSP chord/key path; Basic Pitch + note-native is the only audio engine
- **`AudioExtractor.extract` now runs a single front-end: Basic Pitch transcription → note-native chords/key/contour.** The YIN + FFT-chroma DSP pipeline that produced the long-standing chord-accuracy gap (GADA 40.6% / TaylorNylon 31.2% root) was deleted; the note-native path it's replaced with scores **GADA 100% root / 93.8% exact, TaylorNylon 99.1% root / 92.7% exact** (canonical pitch-class metric, `RealAudioChordTests`/`BasicPitchChordBench`). Key (`ProgressionAnalyzer` over the note-native chords, with `MelodyKeyInference` as the no-chord fallback), the melodic-skyline `contour`, and full-polyphony `detectedNotes` all derive from the same transcription. **`Result` shape is unchanged.**
- **Deleted (compiler/tests proved them dead once the `.dsp` path was removed):** `PitchDetector` (YIN), `OnsetDetector` (RMS), `ChromaExtractor` (FFT chroma), `ChordDetector` + `IntervalDetector` + `ChordClassifierProvider` (chroma+template chord detection), `CanonicalChromaLibrary` + `ChromaTemplateLibrary` (canonical-chroma template library), `NoiseCalibrator` + `NoiseBaseline`. **Kept:** `NoteChordIdentifier` and the note-native chord path, `MelodyKeyInference`, `ProgressionAnalyzer`, the Instruments/Guitar voicing subsystem, the tempo subsystem (`BeatTracker`, `TempoEstimator`, `SpectralFluxOnsetDetector`, `TempoHistogram`), `ContourNote`/contour derivation, and `DSPUtilities` (windowing/FFT helpers, still used by tempo).
- **`AudioExtractor.Configuration.noteSource` and the `NoteSource` enum were removed** (the switch no longer exists — Basic Pitch is the only path; "field removed" end-state). The remaining `Configuration` DSP-tuning fields (`onsetMinGapMs`, `chromaWindowSize`, …) are retained as **vestigial** so existing call sites stay source-compatible; the Basic Pitch path does not read them (a deliberate follow-up could strip them).
- **Known limitation:** the Basic Pitch path does **not** gate pure-digital-silence input — an all-zero buffer can yield a few spurious low-confidence notes (and therefore a key), where the removed DSP path gated this via an energy/onset threshold. Real captures carry a noise floor. An energy guard is a candidate follow-up (needs device validation against quiet nylon captures); tracked in `TASKS.md`.
- **Public API:** removes the `.dsp`/`.basicPitch` `NoteSource` enum and `Configuration.noteSource`; `AudioExtractor.extract`, `Result`, `ChordSegment`, and the music-theory/contour/tempo/voicing surfaces are unchanged. Suite green with the same two GuitarSet expected failures (the two `RealAudioChordTests` allowlist entries were removed — they now pass).

### Fixed — `.basicPitch` key/harmony read from full polyphony, not the melody skyline
- **`extractViaBasicPitch` set `Result.detectedNotes` to the melody skyline reduction.** Sanctuary's melody-key inference AND its harmony timeline both consume `Result.detectedNotes`, so a single melodic line dropped the harmonic content they need — an instrument take (D–A) misread as C♯ minor instead of D/A major. Fix: `detectedNotes` is now the **full polyphonic** transcription (every `TranscribedNote` → `DetectedNote`); `Result.contour` is derived from a locally-computed skyline so it stays a single melodic line. Verified: full-poly `MelodyKeyInference` reads testspanish (romance de amor) as **E minor (0.95)**, testandy as **G♯ minor (0.88)**. Chords are unaffected — `noteNativeChordSegments` runs over the full `TranscribedNote`s, not `detectedNotes` (bench unchanged: GADA 100.0/100.0, TaylorNylon 99.1/99.1). Primary path taken (full-poly `detectedNotes`); the surgical fallback (skyline `detectedNotes` + full-poly `Result.key`) was not needed. No public API change.

### Fixed — `unsafeForcedSync` structural-concurrency hazard in the Basic Pitch model compile
- **`BasicPitchTranscriber` compiled the bundled `.mlpackage` by bridging the async `MLModel.compileModel(at:completionHandler:)` with a `DispatchSemaphore.wait()`.** `init` is a synchronous throwing initializer reached from a Swift Concurrency context (`AudioExtractor.extract(.basicPitch)` runs inside a `Task`), so the semaphore wait blocked a cooperative-pool thread — the "Potential Structural Swift Concurrency Issue: unsafeForcedSync called from Swift Concurrent context" hazard. Fix: use the **synchronous** `MLModel.compileModel(at:)` (no dispatch wait), removing the only blocking primitive in `Sources/`. App/device builds ship the precompiled `.mlmodelc` and don't hit this path at all; the CLI/test `.mlpackage` fallback now compiles without blocking a cooperative thread. Clean build (no deprecation/other new warnings); full suite unchanged (4 expected failures, 0 unexpected). No public API change.

### Changed — NoteChordIdentifier: per-quality prior cuts spurious aug/sus/7th names
- **Added a per-quality prior to `NoteChordIdentifier`** (`qualityPrior`, subtracted from the score). On-device reads of real fingerpicked guitar over-fired augmented/suspended/7th names (`C+`, `G♯+`, `Esus2`, `Bsus4`, `Gmaj7`) when the distinguishing tone (♯5, sus 2nd/4th, added 7th) was only weakly present. The prior — augmented penalized hardest (rare in this repertoire), sus/maj7 next, 7ths/dim lighter, plain major/minor zero — makes a colored name win only when its color tone carries enough weight, so plain triads win on near-ties. Verified no regression: `NoteChordIdentifierTests` 11/11 (full-strength color tones still name the colored chord by a wide margin); the labeled head-to-head bench held GADA bp-note-native at 100.0/100.0 root/exact and **improved** TaylorNylon from 96.3/96.3 to **99.1/99.1**. On the three real recordings the augmented misfires went to **zero** and sus was reduced (morning evidence in the session report). No public API change.

### Changed — Basic Pitch + note-native chord engine in AudioExtractor (staged behind a switch, then promoted)
- **The Basic Pitch + note-native path was wired into `extract` behind a `Configuration.noteSource` switch (default `.dsp`) as a reversible staging step, then promoted to the only path in this release (the switch + the `.dsp` pipeline were removed — see "Removed" above).** One `BasicPitchTranscriber` pass (model compiled+loaded once, process-wide, via a cached `static let` — no per-call recompile) feeds `noteNativeChordSegments` (full-polyphony → `NoteChordIdentifier`, 1.0 s/0.5 s windows collapsed into contiguous non-overlapping segments) for chords, a `skyline` melodic reduction for `contour`, full-polyphony `detectedNotes`, and the `deriveContour` / `inferKey` / `Result` machinery for the rest (the accurate note-native chords carry the full-poly signal into the chord-based key branch). `ChordSegment.DetectionMethod` is **not** extended — segments reuse the existing `.classifier` case (the enum is frozen for Sanctuary; a `.noteNative` case is a later additive option). The path loads a Core ML model, so `AudioExtractor` is no longer a pure / no-I/O function.

### Fixed — Basic Pitch model failed to load inside an app (`.basicPitch` yielded zero notes)
- **`BasicPitchTranscriber.init` resolved the bundled model only as `nmp.mlpackage`.** An Xcode **app** build runs `coremlc` on the `.mlpackage` resource and ships the *compiled* `nmp.mlmodelc` in `MusicCraftCore_MusicCraftCore.bundle`, so `Bundle.module.url(forResource: "nmp", withExtension: "mlpackage")` returned nil inside an app → init threw `.modelResourceMissing` → the cached transcriber was nil → `extract(.basicPitch)` silently degraded to an empty `Result` (Sanctuary saw `chords=[] key=—` on real polyphonic input). `swift build`/tests never exposed it: the SwiftPM CLI does **not** run `coremlc`, so the `.mlpackage` shipped verbatim and resolved (MCC's own tests pass). Fix: resolve the **compiled `.mlmodelc` first** (load directly, no runtime compile), then fall back to compiling the `.mlpackage` at runtime — both build pipelines now work. Verified in the Sanctuary Simulator app (model loads from `nmp.mlmodelc`; inference returns notes). No public API change; `.dsp` path untouched.

### Changed — Basic Pitch transcriber, Phase 2 prerequisite (toward 0.0.15)
- **Overlapping inference windows + seam trimming (matches upstream `unwrap`), removing window-boundary artifacts.** `BasicPitchTranscriber.transcribe(_:sampleRate:)` previously windowed audio into *non-overlapping* `AUDIO_N_SAMPLES` chunks and concatenated each window's full output, so the model's edge-degraded predictions stitched together into seam artifacts (split notes / spurious onsets) about every 2 s. It now mirrors `spotify/basic-pitch` @ `fa5997af` (`inference.py`: `get_audio_input` / `window_audio_file` / `unwrap_output`): front-pad by `OVERLAP_LEN/2` (3840) zeros, window with stride `HOP_SIZE` (36164) so windows overlap by `N_OVERLAPPING_FRAMES` (30), trim `N_OVERLAPPING_FRAMES/2` (15) frames from each window edge on unwrap, then tail-trim the concatenation to `int((origLen/HOP_SIZE) * (ANNOT_N_FRAMES − N_OVERLAPPING_FRAMES))` frames. Time alignment is preserved — the front-pad and the first window's leading edge-trim cancel exactly (15 frames each), so the existing `frame · secondsPerFrame + alignmentOffset` mapping is unchanged (verified: a tone after 0.5 s silence still onsets at ~0.5 s). New seam test (`testLongToneIsContinuousAcrossWindowSeams`): a 5 s tone now decodes to a continuous note spanning multiple window boundaries — not one fragment per window — with no seam-aligned onset. Determinism preserved. Yellow: changes the output of the public, currently-unwired `BasicPitchTranscriber` (no consumer yet); `AudioExtractor`/`PitchDetector`/`OnsetDetector`/`Result` and the decoder untouched.

## [0.0.14] - 2026-05-31

### Added — Basic Pitch adoption, Phase 1 (transcriber + bundled model; additive, no wiring)
- **`BasicPitchTranscriber`** (new `Sources/MusicCraftCore/Transcription/` area) — wraps Spotify's bundled **Basic Pitch** Core ML model (audio → polyphonic note events + frame-level pitch contour). `transcribe(_:sampleRate:)` resamples a mono buffer to the model's 22050 Hz rate (vDSP), runs inference, and decodes the model's note/onset/contour activations into `[TranscribedNote]` + `[PitchFrame]` + `duration`. Public types: `BasicPitchTranscriber` (`Configuration`, `Transcription`, `TranscriptionError`), `TranscribedNote`, `PitchFrame`.
- **Bundled model resource** `Sources/MusicCraftCore/Resources/nmp.mlpackage` — Spotify's official Core ML serialization, used as-is (Apache-2.0). Declared `.copy` (preserves the `.mlpackage` directory; `.process` flattens it). `Package.swift` stays `dependencies: []` — Core ML is a system framework, zero new third-party deps. License at `BASIC_PITCH_LICENSE.txt`; attribution + SHA-256 in `NOTICE`.
- **`BasicPitchDecoder`** — faithful Swift re-implementation of Basic Pitch's note-decoding algorithm (`output_to_notes_polyphonic`, `get_infered_onsets`, `argrelmax` peak-pick, the melodia trick); pure numeric, no upstream Python vendored. Velocity = mean note activation (ported); pitch-bend deferred in Phase 1 (`pitchBend == nil`).
- **Security analysis filed** at `docs/security/basic-pitch-2026-05-31.md` (the gating third-party-integration review): provenance + SHA-256, "serialized NN, no exec path", bounds-safe resampler, throw-based error design, and the **on-device packet-capture step (Chris)** that gates the tag. Classified **SAFE TO ADOPT**.
- **No wiring.** `AudioExtractor`, `PitchDetector`, `OnsetDetector`, and all `Result` types are untouched. Fully reversible (delete the type + the resource).

#### Verified against upstream (before freezing the API)
- Artifact + I/O confirmed against `spotify/basic-pitch` @ `fa5997af` (release v0.4.0): input `input_2` `(1, 43844, 1)` mono @ 22050 Hz; outputs `Identity`→contour (264), `Identity_1`→note (88), `Identity_2`→onset (88). Velocity/pitch-bend are Python post-processing, not model outputs.

#### Tests
- `BasicPitchTranscriberTests` — resampler (bounds/behavior) and the note decoder pass on the CLI; the model-dependent tests (load, inference produces notes, **determinism: byte-identical output across runs**, empty-buffer) **also ran and passed under `swift test`** on macOS (Core ML loads the bundled model at runtime). 11/11 pass.

#### Egress gate — cleared at library level (2026-05-31)
- The third-party-integration gate's egress condition is satisfied at the library level by three independent layers: **static** — no networking symbols anywhere in `Sources/` (no `URLSession`/sockets/`Process`/host resolution), so no code can exfiltrate; **runtime capability proof** — under `sandbox-exec` denying network-outbound/inbound/bind, `BasicPitchTranscriberTests` (11/11, incl. the byte-identical determinism test) pass, so model load + inference require no network; **observational** — `lsof`/`nettop` showed no sockets for the test process (sampling-based corroboration). macOS 26.3.1. Detail recorded in `docs/security/basic-pitch-2026-05-31.md` (§6 + Egress verification results).
- **App-level on-device confirmation inside Songcatcher** (capture → transcription with the app's full entitlements) remains a **Phase 2** step — it only becomes runnable once the transcriber is wired into the app. Correct scope, not a gap in this library-level evidence.

### Versioning
- `musicCraftCoreVersion` → "0.0.14". `MusicCraftCoreTests.testVersionIsSet` updated to assert "0.0.14".

### Tier / classification
- Tier 2 / yellow at the code level (additive: one new public `Transcription` area + a bundled model resource; `AudioExtractor` and its `Result` untouched). The release/tag op is behind the red tag gate (Chris-authorized for this 0.0.14 release). 3-component SemVer tag only.

## [0.0.13] - 2026-05-30

### Changed
- **SwiftPM-resolvable re-release of the G♯-minor enharmonic spelling fix.** The fix shipped in 0.0.12.1, but `0.0.12.1` is a 4-component tag and not valid SemVer; SwiftPM's `from:` solver cannot resolve it. Verified by probe: a `from: "0.0.12"` consumer locks 0.0.12 and ignores the 0.0.12.1 tag even after `swift package update`, and `from: "0.0.12.1"` fails manifest evaluation ("Invalid semantic version string"). 0.0.13 carries the identical fix on a 3-component tag so `from: "0.0.12"` consumers resolve it on a normal `swift package update`. No code change from 0.0.12.1 — `keyUsesFlats` already drops `.Gs`; G♯ minor spells G♯m, A♯°, B, C♯m, D♯m, E, F♯.

### Versioning
- `musicCraftCoreVersion` → "0.0.13". The non-resolvable `0.0.12.1` tag is left in place (inert for SwiftPM) but superseded; consumers adopt 0.0.13.

### Tier / classification
- Tier 2 — release/tag op behind the red tag gate (Chris-authorized). No logic change.

## [0.0.12.1] - 2026-05-30

### Fixed
- **`DiatonicChordGenerator` spelled G♯ minor's diatonic chords in flats**, contradicting the sharp key label. `keyUsesFlats(root:mode:)` classified G♯ minor (a 5-sharp key) as a flat key, so `generate(for:)` emitted A♭m / B♭° / … and `spelledRoot` / `keyDisplayName` returned A♭ for a key the rest of the library displays as G♯ minor (A♭ minor is the unused 7-flat enharmonic). Fix: removed `.Gs` from the minor branch of `keyUsesFlats`. The seven diatonic chords now follow the conventional G♯-minor spelling: G♯m, A♯°, B, C♯m, D♯m, E, F♯. Pre-existing bug; predates and is independent of the 0.0.12 MelodyKeyInference rewrite.

### Public API
- No signature change. `generate(for:)`, `spelledRoot(for:)`, `keyDisplayName(for:)` are shape-identical; their **output strings change for G♯ minor inputs only** (flat → sharp). Any consumer snapshot/test asserting the old A♭-minor spelling must update. Flagged to Sanctuary via cross-project-log.

### Tests
- Added regression coverage asserting G♯ minor's diatonic chord names and root spelling are sharp.
- Version assertion updated to 0.0.12.1.

### Tier / classification
- Tier 2 — yellow code change (behavior fix to an internal speller; no public signature change) behind the red tag gate (Chris-authorized).

## [0.0.12] - 2026-05-30

### Changed
- **`MelodyKeyInference` rewritten with tonal-profile (Krumhansl–Kessler) correlation.** The prior algorithm scored a key by the fraction of sung pitch classes diatonic to its scale — but a major key and its relative minor share a scale, so they always tied, and the tie-break hard-preferred minor. Every inference was a major-vs-relative-minor coin toss biased to minor. The new algorithm builds a **duration-weighted** (confidence-modulated) 12-bin pitch-class profile from the notes and scores all 24 keys by **Pearson correlation** against the Krumhansl–Kessler tonal hierarchy rotated to each tonic (Krumhansl 1990, Table 2.1). Because a major key and its relative minor have *different* profiles, they now score differently — the minor bias is gone, and duration emphasis on the tonic triad decides the relative pair.
  - The hard "prefer minor" tie-break is **removed**. Ranking uses a total-order comparator (correlation, then tonic note-count, then a stable non-mode order), which also makes the result **fully deterministic run-to-run** (the old score-tie sort was order-unstable).
  - Krumhansl–Kessler profiles live as named constants (`kkMajor` / `kkMinor`); Temperley/Aarden variants are drop-in swappable.
  - Guards unchanged: ≥3 notes and ≥2 distinct pitch classes, else `[]`.

### Public API
- No signature change. `MelodyKeyInference.infer(from:maxCandidates:)` and the `KeyCandidate` shape (`key`, `score`, `tonicFrequency`) are identical.
- **`KeyCandidate.score` semantics changed** (behavior, not shape): it is now the winning KK-profile correlation clamped to `[0, 1]`, not the old diatonic fraction. **Consumer impact:** Sanctuary's `HarmonyKeyGate` threshold (0.6) was calibrated to the old scale and will need recalibration against the new score distribution — see the cantus-eval re-run. No gate changed in this release.

### Tests
- Updated `MelodyKeyInferenceTests` whose expected scores/outputs changed (C-major scale score is now a correlation, not 1.0; A-minor scale now emphasizes the tonic triad by duration to resolve to minor; the former "tied frequency prefers minor" test now asserts major-triad content resolves to **major**).
- Added relative-pair capability tests: same scale content resolves to major or minor purely by which tonic triad is held longer.
- Full suite: 356 → 358 tests (+2). Failing set unchanged (the 4 pre-existing chord/GuitarSet-accuracy allowlist entries).

### Tier / classification
- Tier 2, yellow: single-subsystem algorithm rework, no public API signature change. Held for tag/version approval per the red posture on tag operations; consumer (Sanctuary) recalibration pending.

## [0.0.11] - 2026-05-12

### Changed
- **`TempoEstimator` buffer path rewritten with spectral-flux onset detection.** Replaces the RMS-energy-based onset signal that produced 0% accuracy with systematic 1/3-tempo error on real guitar audio (Phase 3.2 / 3.3 GuitarSet measurements). The new algorithm uses Dixon 2006 half-wave-rectified spectral flux with adaptive median thresholding, peak picking with a 50ms minimum gap, and a 1-BPM-resolution tempo histogram with internal 2x/0.5x octave-candidate handling.
- **`TempoEstimator.estimateTempo(beats:)` harmonic-candidate ranking fixed.** Previously `harmonicConfidence = regularity * (1.0 / ratio)`, which made 0.5x candidates outrank the base. Replaced with a fixed `regularity * 0.5` octave-error penalty so the base IBI-derived BPM ranks first on regular beat streams. `testGuitarSetTempoAccuracy` moved from 0% within ±10% to 100% within ±5% on the 5-fixture GuitarSet subset; removed from the pre-push known-failing allowlist.
- **`TempoEstimator.Configuration` defaults shifted.** `onsetWindowSize` 2048 → 1024, `onsetHopSize` 1024 → 512 to match the spectral-flux detector's per-frame granularity. Observable to callers passing stored Configuration values; callers using `Configuration()` see no change beyond the underlying algorithm shift. `harmonicRatios` is retained but no longer consulted on the buffer path (the new algorithm generates 2x/0.5x candidates internally).
- **`BeatTracker.detectBeats(buffer:sampleRate:)` rewired** to call `SpectralFluxOnsetDetector` for the onset signal. Its `Configuration` defaults shift identically (1024/512); the autocorrelation step and minAutocorrPeak/inertia fields are no longer consulted (retained for backward compatibility).
- **`TempoEstimate.confidence` doc-comment updated.** Buffer path: fraction of histogram evidence at this BPM. Beats path: inter-beat-interval regularity (1 − std/mean). Consumers should gate display on `confidence ≥ 0.3` to suppress unreliable estimates on low-rhythm material (e.g., monophonic vocals).

### Added
- Internal `SpectralFluxOnsetDetector` (`Sources/MusicCraftCore/DSP/SpectralFluxOnsetDetector.swift`): pure function returning onset times via STFT + spectral flux + adaptive thresholding.
- Internal `TempoHistogram` (`Sources/MusicCraftCore/DSP/TempoHistogram.swift`): pure function returning ranked BPM peaks from a list of onset times. Primary IOI-derived candidate weighted 1.0; 2x/0.5x octave variants weighted 0.5 to break ties in favor of the unambiguous reading.
- `SpectralFluxTempoTests`: 8 new tests covering the regression fixture (120 BPM click track, formerly returning ~40 BPM in the 1/3-bug), histogram correctness on synthetic regular onsets, low-rhythm-content confidence behavior, and detector edge cases (empty, silence).
- `GuitarSetTempoBufferTests.testBufferDerivedTempoConfidenceContract`: real-audio assertion that the algorithm never produces a high-confidence wrong tempo on percussive guitar. On the 5-fixture GuitarSet subset, 1/5 fixtures returns an accurate estimate; the remaining 4/5 return low-confidence estimates (0.05–0.09) that the consumer display gate (0.3) correctly suppresses. This is the load-bearing contract for the Sanctuary consumer use case — pre-0.0.11 the algorithm produced high-confidence wrong tempo with no display-gate signal.

### Public API
- No breaking changes. `TempoEstimator.estimateTempo(beats:buffer:sampleRate:configuration:)`, the `Configuration` struct shape, `TempoEstimate` shape, and `BeatTracker.detectBeats(buffer:sampleRate:configuration:)` are signature-identical. Behavior shifts and Configuration default shifts are documented above.

### Honest measurement notes
- Buffer-derived accuracy on real guitar audio: 1/5 (20%) within ±10% on the 5-fixture GuitarSet subset, below the 40% target stated in `specs/0.0.11-tempo-spectral-flux.md`. The 4 inaccurate cases return confidence 0.05–0.09 — below the 0.3 display gate — so the consumer correctly suppresses display. This is the spec's "experimentation mode; honest measurement matters more than hitting an aspirational number" outcome.
- JAMS-fed accuracy: 100% within ±5% on the same 5-fixture subset after the harmonic-confidence fix.

See `specs/0.0.11-tempo-spectral-flux.md` for full algorithm and rationale.

## [0.0.10.1] - 2026-05-12

### Fixed
- **LyricsExtractor multi-hypothesis flattening:** `transcribe(...)` previously included every alternative hypothesis from `SFSpeechRecognitionResult.transcriptions` via `flatMap`, producing 3x-duplicated transcripts on songs with multiple plausible interpretations (Sanctuary 2026-05-12 device test, 32s vocal capture). Fix: take only `result.transcriptions.first?.segments`. Single-hypothesis return is the correct semantic for the current consumer surface; alternatives can be exposed via a separate entry point in a future release if needed.
- **LyricsExtractor long-buffer truncation:** One-shot `append+endAudio` on a single full-buffer `AVAudioPCMBuffer` truncated clips longer than ~30s (Sanctuary earlier device test, 56s capture transcribed only ~25s). Fix: slice the input buffer into 1-second chunks and `append` each as a separate `AVAudioPCMBuffer` before calling `endAudio`. Keeps the recognizer's stream engaged across the full duration.

### Public API
- No changes. `LyricsExtractor.transcribe(...)` signature, `Configuration` struct, `SpeechFrameworkError` cases, and `TranscribedToken` shape are identical to 0.0.10.

### Tests
- `testSingleHypothesisShape` asserts monotonic onset times on the longest available TTS fixture (regression for the `flatMap` bug).
- `testFullDurationCoverage` concatenates the longest TTS fixture to build a ≥30s buffer and asserts the last token ends within 5s of the buffer end (regression for the truncation bug).
- Both tests skip on macOS / when SFSpeechRecognizer is unavailable, matching the existing `testLyricsExtractorAccuracy` on-device guard.

See `specs/0.0.10.1-lyrics-extractor-fix.md` for full diagnosis and design rationale.

## [0.0.10] - 2026-05-08

### Added
- **Instruments/Guitar subsystem (new):** Voicing library, capo calculator, and voicing scoring for chord accompaniment suggestions.
  - GuitarTuning: 6 standard tunings catalog (Standard, Drop D, Open D, Open G, DADGAD, CGDGBD) with semitone intervals and reference frequencies.
  - VoicingPosition: Fretboard shape data (frets, fingers, barres, baseFret, requiresCapo) with Codable legacy field mapping (capo → requiresCapo).
  - GuitarVoicing: Position + chord + tuning metadata with computed displayName.
  - VoicingLibrary: Chord → ranked voicings lookup. Standard tuning only in 0.0.10; per-tuning data deferred to 0.0.11.
  - CapoCalculator: Target key → capo position suggestions with diatonic-chord-richness scoring. Mode-preserved (major → major, minor → minor).
  - VoicingScore: Composable voicing scoring with fingeringDifficulty, openness, positionScore, spanScore, and weighted totalScore. Default criteria: 0.4 difficulty, 0.3 openness, 0.2 position, 0.1 span (tuned for singer-songwriter use case).
  - guitar_voicings.json: Curated resource (72 chord-name keys × 2–3 voicings) ported from legacy Cantus with rank 1 (open), rank 2 (barre), rank 3 (alternate for easy keys) selection.
  - Test coverage: GuitarTuningTests, VoicingPositionTests, GuitarVoicingTests, VoicingLibraryTests, CapoCalculatorTests, VoicingScoreTests. All passing.
  - Enables Sanctuary slice 9.3 (vocal harmony suggestions): sung melody → inferred key → diatonic chord candidates → tappable voicings with capo positions.

### Known Limitations (0.0.10)
- Diminished and augmented voicings not bundled (diatonic gaps for vii° major / ii° minor).
- Non-standard tunings return empty from VoicingLibrary (per-tuning data deferred to 0.0.11).
- Cross-mode capo mapping (relative major↔minor) deferred to 0.0.11.
- Chord substitution suggestions not implemented.
- Left-handed mirroring not implemented.

### Tier 1 Discipline
- New subsystem with multiple public types and new architecture pattern (Instruments/Guitar/).
- Released after Chris review of design spec, implementation, and post-Phase-B drift acknowledgments (rank-3 voicing scope expansion, filtered-test masquerade fix-forward in commit 9a2b61c).
- Phase reports use canonical template; Capability-Context Fit audit confirmed fit for Sanctuary slice 9.3 consumption.

### Added
- **Phase 3 GuitarSet integration test infrastructure:** Real-audio testing on polyphonic multi-chord guitar excerpts with JAMS annotations.
  - JAMSParser: minimal Swift JSON parser for JAMS (chord_harte, beat, key_mode namespaces only). Harte notation translator (e.g., `A:min` → `Am`). Scope-limited to GuitarSet files; no external dependencies.
  - GuitarSetFixture: 20 acoustic guitar excerpts from Zenodo dataset (CC-BY 4.0, NYU MARL + Queen Mary). Fixture loading with JAMS parsing and lazy WAV audio decoding.
  - GuitarSetDownloaderTests (gated `MCC_DOWNLOAD_GUITARSET=1`): downloads annotation.zip and audio_hex-pickup_debleeded.zip from Zenodo record 3371780 via Zenodo API. Extracts 20 target files per genre (BossaNova, Funk, Rock, Singer-Songwriter). Writes MANIFEST.txt with SHA256 verification and CC-BY attribution. Idempotent (skips existing files with matching hashes).
  - AudioAnalysisMetrics extensions: ProgressionMetrics (CSR at majMin vocabulary, median timing deviation, no-detection fraction), TempoMetricsExtended (tempoError, within5pct/10pct/20pct tolerances, halftime/doubletime error detection), KeyMetrics (exactMatch, relativeKeyMatch, rootMatch, ground truth vs detected comparison).
  - GuitarSetProgressionTests, GuitarSetTempoTests, GuitarSetKeyInferenceTests: test suites for chord progressions (CSR frame-by-frame at 10ms), tempo estimation (from beat times), and key inference (chord-rich material only). Thresholds calibrated to literature baselines with explicit calibration-down rules.
  - Security evaluation: `docs/security/phase-3-guitarset-evaluation.md` documents threat model (no code injection, safe unzip usage, JSONDecoder-only parsing).
  - **Scope limitation:** Phase 3 measures key inference on chord-rich comping material only. MelodyKeyInference pitch-class fallback path NOT exercised. Do not claim general key-inference accuracy from Phase 3 results.
  - Documentation: Fixtures/real-audio/guitarset/README.md with JAMS format spec, Harte notation guide, Zenodo citation, scope limitation.

### Added
- **Real-audio fixture integration (Phase 2.5, corrective):** GADA + TaylorNylon guitar recordings from legacy Cantus, 32+109 WAV files with ground-truth JSON sidecars. Replaces Phase 2's ineffective SoundFont synthetic approach.
  - Fixture sources: 32 GADA files (3 guitar models, 12 common chords, fingerstyle) + 109 TaylorNylon files (7 chord types, nylon classical timbre).
  - JSON sidecars encode single-chord ground truth (chord name, confidence=1.0) using GroundTruthCodable envelope.
  - RealAudioChordTests: per-file accuracy comparison (root + exact chord) against Phase 2.5 measured baseline (GADA: 40.6% root / 68.8% exact; TaylorNylon: 31.2% root / 49.5% exact). Thresholds reflect AudioExtractor's real performance on this subset, calibrated to detect regression, not match legacy Cantus Stage 2 (which achieved 99.7% on full 3449-sample dataset).
  - Package.swift: resources declaration copies AudioAnalysis/Fixtures to test bundle.
  - SidecarGenerationTests (gated MCC_GENERATE_SIDECARS=1): regenerates JSON sidecars from WAV files if needed.
  - Confusions analysis: GADA harmonic confusion (Em/E→B patterns), TaylorNylon nylon timbre overlap (Fm→G♯, F→A patterns).
  - Documentation: Fixtures/real-audio/README.md with source provenance, measurement methodology, confusion categorization, maintenance guidance.

- **Audio analysis testing infrastructure (Phase 1):** Synthetic fixture baseline + test harness for chord, tempo, and note detection validation.
  - AudioFixtureLoader: lazy fixture loading with support for synthetic audio generation (all-major-triads, all-minor-triads, common-sevenths, steady-tempo metronome, C major scale) and optional ground-truth annotations.
  - SyntheticGenerator: static helper methods for creating test audio (generateSineWave, generateChordBuffer, generateMetronomeClick, etc.) with envelope modeling (attack, sustain, release).
  - GroundTruth: enum annotation types for chord progressions, tempo, melody notes, and lyrics with timing and confidence metadata.
  - AudioAnalysisMetrics: mir_eval-inspired chord comparison (rootAccuracy, qualityAccuracy, exactAccuracy, timingDeviation, falsePositives, falseNegatives) using majMin chord reduction and timing tolerance windows. Also includes tempo and note comparison metrics.
  - SyntheticChordTests, SyntheticTempoTests, SyntheticNoteTests: structural validation tests for extraction pipeline (correctness validation deferred to real-audio Phase 2 with GADA dataset).
  - All tests pass (290/290 suite). Documentation: docs/AUDIO_TESTING_STRATEGY.md with 7-section specification of test fixtures, metrics, harness architecture, and 5-phase implementation plan.

## [0.0.9] - 2026-04-26

### Added
- **Voice subsystem (new):** LyricsExtractor for on-device lyric transcription using Apple's Speech framework.
  - LyricsExtractor: async transcribe method wrapping SFSpeechRecognizer (iOS 17+ baseline) with forward-compatible path to SpeechAnalyzer (iOS 26+) via feature detection in future releases.
  - TranscribedToken: timestamped word-level tokens with text, onsetTime, duration, optional confidence (iOS 26+ only).
  - SpeechFrameworkError: wrapped error handling for framework unavailability, recognition failures, locale mismatch, and permission denial.
  - Enables lyric-based search and analysis in consumer apps (e.g., Sanctuary hum-to-search with lyric matching).

- **DSP subsystem expansion:** BeatTracker and TempoEstimator for rhythm analysis.
  - BeatTracker: beat detection via onset strength signal autocorrelation (RMS-based energy per frame, Accelerate-optimized). Configuration tuning: window/hop sizes, beat period range (20–200 BPM), autocorrelation threshold, inertia parameter for beat stability.
  - TempoEstimator: tempo estimation from pre-detected beats or directly from audio buffer. Returns ranked candidate tempos with confidence scores and harmonic classification (captures tempo ambiguities from syncopation, rubato, triplets). Reuses BeatTracker for buffer path.
  - TempoEstimate: public struct with bpm, confidence, isHarmonic flag for client-side tempo disambiguation.
  - Both subsystems fully independent (no coupling between BeatTracker and TempoEstimator; coordinated onset computation deferred to 0.0.10+).

### Known Limitations
- **Real-audio fixtures deferred:** 0.0.9 ships with synthetic fixture tests only (structural validation, no algorithm accuracy on real audio). Real-audio ground-truth evaluation (beat accuracy, tempo estimation on live recordings) bundled with deferred 0.0.8 real-audio fixtures in 0.0.9.1 patch or 0.1.0 release.
- **LyricsExtractor per-token confidence:** iOS 17 path (SFSpeechRecognizer) does not expose per-token confidence; confidence field always nil. SpeechAnalyzer (iOS 26+) with per-token confidence deferred to 0.0.10 as iOS 26 adoption broadens (currently ~60–70% market reach).
- **Beat inertia parameter:** Exposed in BeatTracker.Configuration but not actively used in beat induction algorithm (baseline inertia = 0.5). Sophisticated Viterbi/HMM-based tempo tracking deferred to post-0.1.0.
- **Tempo range:** 300–3000ms (20–200 BPM) covers typical pop/rock. Very slow music (<20 BPM, e.g., classical adagio) may be detected at double/triple/quarter tempo. Configurable via minBeatPeriodMs/maxBeatPeriodMs.
- **Beat detection algorithm:** Autocorrelation-based; tempogram + Viterbi and ML-based refinement deferred to future releases.

### Consumer Adoption Recommended
- **Sanctuary:** Phase D search integration — lyric matching on LyricsExtractor tokens, rhythm-aware analysis using BeatTracker/TempoEstimator.
- **Cantus:** Rhythm UI features — beat visualization from BeatTracker, tempo awareness from TempoEstimator.
- **Guitar Atlas:** Rhythm transcription support (future work pending real-audio validation in 0.0.9.1).

## [0.0.8] - 2026-04-25

### Added
- AudioExtractor: offline audio analysis pipeline composing all MCC subsystems (DSP primitives, music theory types, chord detection, pitch detection, key inference) into a unified Result struct with chord segments, inferred key, melodic contour, detected notes, and buffer duration.
- AudioExtractor.Configuration: tuning parameters for onset detection (minGapMs, energyMultiplier, energyFloor), chroma analysis (windowSize, hopSize), early-frame windowing (attackSkip, windowSize), extraction confidence thresholds, and silence threshold for noise calibration.
- AudioExtractor.Result: public struct bundling chordSegments, inferred MusicalKey, ContourNote contour, DetectedNote array, and duration.
- AudioExtractor.ChordSegment: public struct with UUID id, start/end times, detected Chord, confidence score, and DetectionMethod enum (classifier/interval/agreement).
- ContourNote and ParsonsCode: melodic pitch trajectory with direction codes (up "*", down "d", repeat "r") per MIR literature. First note convention: pitchSemitoneStep=0, parsonsCode=.repeat_ for no-predecessor case.
- DetectedNote: raw monophonic note event with MIDI note, absolute timing, duration, confidence, and computed pitchClass property.
- MelodyKeyInference: key inference via diatonic-fit scoring on 24 keys (12 roots × 2 modes), with tie-breaking by tonic frequency count and minor mode preference. Returns ordered KeyCandidate array with key, score, tonicFrequency.
- OnsetDetector: energy-based note onset detection using RMS energy with running average threshold (multiplier × previous_average). Configurable gap enforcement to prevent sub-threshold repeats.
- NoiseCalibrator: silence frame detection via RMS threshold; averaged chroma extraction from silence windows for noise baseline subtraction. Contamination limit prevents non-silence baselines.
- NoiseBaseline: public struct with chroma vector and frameCount for noise-aware analysis.
- Sendable conformance on Chord and ChordQuality (additive; required for AudioExtractor.ChordSegment Sendable conformance).
- Hashable conformance on Chord (additive; non-breaking).

### Changed
- Chord struct now conforms to Hashable and Sendable in addition to Equatable and Identifiable. Non-breaking.
- ChordQuality enum now conforms to Sendable. Non-breaking.

### Known Limitations
- AudioExtractor pipeline tests in 0.0.8 are structural-only. Synthetic test fixtures (sine waves with smooth envelopes) cannot drive OnsetDetector's RMS-energy threshold reliably enough to validate end-to-end chord detection and key inference correctness. Real-audio fixture tests with recorded guitar and vocal samples are deferred to a future patch release (likely 0.0.8.1 or 0.0.9). Cantus and Sanctuary consumer adoption will exercise the pipeline against real audio in production use.
- Onset detection is energy-based (RMS with running average); spectral flux upgrade deferred to a future MCC DSP enhancement.
- KeyInference and MelodyKeyInference heuristic weights remain internal constants; configurable weights deferred until a consumer requests them.
- ContourNote pipeline assumes monophonic pitched input; polyphonic vocal/instrumental sources produce sparse or empty contour. Sanctuary will validate Configuration defaults against representative vocal recordings during slice 9 integration.

## [0.0.7] - 2026-04-24

### Added
- RomanNumeral value type with Degree, Accidental, and Quality nested enums. Supports diatonic and borrowed chord spelling (♭II Neapolitan, ♭III, ♭VI, ♭VII, ♯IV). Equatable, Hashable, Sendable.
- SongReference value type for citing song examples in pattern libraries. Equatable, Hashable, Sendable.
- ProgressionPattern and RecognizedPattern types describing well-known chord progressions and recognition results. Equatable, Hashable, Sendable.
- ProgressionAnalyzer stateless enum with `inferKey(from: [Chord]) -> MusicalKey?` and `recognizePattern(progression: [Chord], in: MusicalKey) -> RecognizedPattern?` static methods.
- 15-pattern library covering common pop, folk, jazz, rock, and classical progressions with song examples: Pop Anthem, Sensitive/Emotional, Classic Rock/Folk, Jazz Standard, 50s Doo-wop, Andalusian Cadence, Mixolydian Rock, Natural Minor Folk, Building/Uplifting, Dreamy/Nostalgic, Epic/Cinematic, Jazz Turnaround, Plagal Pop, Canon in D, Phrygian Cadence.
- MusicalKey.romanNumeralTyped(for:) companion to existing string-returning romanNumeral(for:).
- Hashable and Sendable conformance on MusicalKey and KeyMode.

### Changed
- MusicalKey now conforms to Hashable and Sendable in addition to Equatable. Non-breaking.
- NoteName now conforms to Sendable to support MusicalKey Sendable conformance.

### Housekeeping
- CHANGELOG: split 0.0.6.1 into its own heading; restored 0.0.6 entry to ChordDetection content.

### Known Limitations
- Pattern library is a static internal array of 15 entries. User-contributed patterns and JSON-based libraries are deferred to a later release.
- KeyInference heuristic weights are internal constants. Configurable weights deferred until a consumer requests them.

## [0.0.6.1] - 2026-04-22

### Fixed
- Release-engineering gap: ChordDetection types were declared without `public` access on Result and Peak initializers, making them unconsumable by external apps. Explicit public initializers added to `ChordDetector.Result`, `IntervalDetector.Result`, and `IntervalDetector.Peak`. Compiler-synthesized memberwise initializers were not promoted to public when accessed from external modules, blocking consumer apps from constructing Result types for adaptation or testing. Issue surfaced by Cantus's 0.0.6 adoption attempt (2026-04-22).
- PublicAPITests extended with direct Result and Peak construction tests via public initializers. Three new tests serve as regression anchors: `testChordDetectorResultPublicInit`, `testIntervalDetectorPeakPublicInit`, `testIntervalDetectorResultPublicInit`.

## [0.0.6] - 2026-04-22

### Added
- ChordDetection subsystem with multi-path chord recognition.
- ChordDetector: chord recognition from chroma vectors using template library matching with multi-path agreement scoring. Tuning knobs: silence calibration threshold, spectral floor subtraction, energy gate multiplier, confidence fallback threshold, agreement boost factors.
- IntervalDetector: interval-based chord detection extracting root and quality from peak-based chroma analysis. Root finding via harmonic series analysis and pitch-class correlation. Quality detection using interval presence scoring and thresholding.
- ChordClassifierProvider protocol: injection point for ML-based or recording-derived chord classifiers. Complementary to template-matching paths.
- Multi-path agreement scoring: ChordDetector scores agreement between template-matching and interval-detection paths with configurable boost factors (full agreement vs. root-only agreement).
- Template pre-filtering: peak-based pre-filter to reduce candidate templates before exhaustive distance matching.
- Comprehensive chord detection test suite validating template matching, interval detection, agreement scoring, and public API accessibility.

## [0.0.5] - 2026-04-22

### Added
- Public access modifiers on all DSP types: `PitchDetector`, `ChromaExtractor`, `CanonicalChromaLibrary`, window functions (Hann, Blackman), FFT wrapper, `DSPUtilities`, noise baseline configuration.
- `ChromaTemplateLibrary` protocol with `distance(_:to:) -> Double` and `availableChordNames: [String]` requirements. Allows consumer apps to inject recording-derived or app-specific template libraries while keeping MCC's algorithms generic.
- `PublicAPITests.swift` exercising the public surface without `@testable import`. Regression anchor against accidental re-privatization in future releases.

### Changed
- Renamed `ReferenceChromaLibrary` → `CanonicalChromaLibrary`. New name more accurately describes the theoretical template library as distinct from consumer-provided recording-derived libraries. The type now conforms to `ChromaTemplateLibrary` as a public struct rather than an internal enum.
- `ChromaExtractor` (and any other DSP type with template-library dependencies) now accepts a `ChromaTemplateLibrary` parameter with `CanonicalChromaLibrary()` as default. Existing call sites are unchanged.

### Fixed
- 0.0.4 release-engineering gap: DSP types were declared without `public` access, making them unconsumable by external apps. Cantus's 0.0.4 adoption attempt (2026-04-22) surfaced the issue. See decisions/mcc-0.0.4-adoption-audit.md in mossgroves-cantus for the full finding.

## [0.0.4] - 2026-04-22

### Added
- DSP subsystem with pure algorithm implementations (no AudioEngine, CoreML, or UI coupling).
- PitchDetector: YIN algorithm with Accelerate/vDSP optimization, confidence-weighted 3-frame median filter, octave jump exemption (12±0.5 and 24±0.5 semitones), pitch jump detection (>3 semitones flushes filter on high confidence).
- ReferenceChromaLibrary: 120 chord chroma templates (12 roots × 10 qualities: major, minor, 7, maj7, m7, dim, aug, sus2, sus4, m(maj7)), Euclidean distance function for template matching.
- FFT wrapper: vDSP-accelerated real-to-complex FFT with split-complex buffer management.
- Window functions: Hann and Blackman windows via vDSP for spectral analysis (Blackman: ~58 dB sidelobe suppression).
- ChromaExtractor: FFT-based chroma extraction with 1/octave weighting (bass frequencies more prominent), noise baseline calibration with 10-frame averaging and 10% floor protection to prevent weak-but-real signals from being zeroed.
- DSPUtilities: Helper functions for window generation, log2 ceiling, and window application.
- Comprehensive DSP test suite: 14 tests covering YIN on sine tones (A440, E329.63, C261.63), confidence degradation on noise, median filter smoothing, window properties, chroma extraction, and ReferenceChromaLibrary.

## [0.0.3] - 2026-04-21

### Added
- Transposer public API explicitly exposed (was public but inaccessible due to module shadowing).

### Fixed
- Removed placeholder `public enum MusicCraftCore` that shadowed module name and prevented qualified type access (e.g., `MusicCraftCore.Transposer`).

### Changed
- Version constant moved from type member to module-level public constant `musicCraftCoreVersion` to avoid shadowing the module name.

## [0.0.2] - 2026-04-21

### Added
- MusicTheory subsystem with core primitives: NoteName, ChordQuality, Chord, Note, MusicalKey
- Note frequency/MIDI conversion utilities (MusicTheory enum)
- Diatonic spelling and chord generation: LetterName, Accidental, SpelledNote, DiatonicChordGenerator, RelatedKeys
- Chord parsing: Chord.init?(parsing:) for parsing chord name strings (e.g., "Am7", "F♯", "B♭dim")
- Transposition utilities: Transposer enum for Roman numeral transposition
- Music theory reference data: music_theory.json with scales, intervals, chord formulas, circle of fifths, progressions, key detection rules
- TheoryReference struct with load() and shared lazy-loaded instance for bundled JSON data
- Comprehensive test suite for all music theory types

### Known Limitations
- Transposer uses fixed sharp/flat spelling (C♯, F♯, G♯, A♯, D♭, E♭, A♭, B♭); user-preference enharmonic rendering is a future enhancement.

## [0.0.1] - 2026-04-21

### Added
- Swift Package skeleton with Package.swift manifest
- Subsystem directory structure (Audio, DSP, ChordDetection, MusicTheory, AnalysisPipeline, Resources)
- Test target with baseline test
- README with project overview and usage documentation
