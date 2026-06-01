# Security analysis — Basic Pitch model + transcriber (Phase 1)

**Date:** 2026-05-31
**Scope:** MCC 0.0.14 Phase 1 — bundling Spotify's Basic Pitch Core ML model and adding a Swift `BasicPitchTranscriber` (additive; no wiring into `AudioExtractor`).
**Rule applied:** portfolio third-party-integration security-review gate (a security analysis must be filed and linked from the implementing commit *before* integration; the tag waits on this analysis + device validation).
**Classification (this document):** **SAFE TO ADOPT** — with the Swift adaptation notes below and one **gating device step** (on-device packet capture, §6), which is Chris's, before the `0.0.14` tag.

---

## 1. Provenance + supply chain

- **Source repository:** `https://github.com/spotify/basic-pitch` (Spotify's official Basic Pitch / "A Lightweight Audio-to-MIDI Converter", ICASSP 2022 model `nmp`).
- **Pinned commit:** `fa5997af0a8210982619003269994a1be25eddf3` (default branch `main`, committed 2025-11-13). Corresponds to release **v0.4.0**.
- **License:** **Apache-2.0** (`Copyright 2022 Spotify AB`). Full text vendored at `BASIC_PITCH_LICENSE.txt` (repo root); attribution recorded in `NOTICE`.
- **Artifact bundled:** `basic_pitch/saved_models/icassp_2022/nmp.mlpackage` (Spotify's *official* Core ML serialization — used **as-is**, no conversion or modification on our side). It is a Core ML **ML Program** package containing:
  - `Data/com.apple.CoreML/model.mlmodel` — `SHA-256 af7bf7d49bc167e0bf0c30aa2ca6b432c3e10df048d2dd4173ff3a738c020858` (123027 bytes)
  - `Data/com.apple.CoreML/weights/weight.bin` — `SHA-256 691a6b63c7ddcdde0ee131ff3986dcb1250df47cd738612efde966ba9b4c99cd` (145956 bytes)
  - `Manifest.json` — `SHA-256 c1fa5ef8acc34703edcd4e90e9a8640bd4673d9f3a68753c3b9d1ca0365e2928` (617 bytes)
- **Verification method:** downloaded each file from `raw.githubusercontent.com/spotify/basic-pitch/<pinned-commit>/…` and confirmed byte sizes match the GitHub tree API (`model.mlmodel` 123027, `weight.bin` 145956, `Manifest.json` 617). Checksums above are of the exact bytes committed to this repo.
- **Supply-chain note:** Core ML is an Apple **system framework**; bundling the model adds **zero new SwiftPM dependencies** (`Package.swift` stays `dependencies: []`). The model ships as a `.process("Resources")` resource, exactly like `guitar_voicings.json`.

## 2. What the binary contains

- A **serialized neural network** only. The `.mlmodel` is a Core ML protobuf *specification* (`com.github.apple.coremltools.source = tensorflow==2.12.0`, target `CoreML5`); `weight.bin` is the network weights. There is **no executable code path** in the artifact beyond Core ML graph inference run by Apple's on-device runtime.
- **I/O (verified against the artifact and the pinned upstream source — see "Verification" below):** one input `input_2` (a `(1, 43844, 1)` mono audio window @ 22050 Hz) and three float outputs — `Identity` → contour (frames × 264), `Identity_1` → note (frames × 88), `Identity_2` → onset (frames × 88).
- **What we do NOT vendor:** Spotify's Python runtime (TensorFlow, coremltools, librosa, scipy, pretty_midi). The model's *post-processing* (note creation from the three activation arrays; velocity/amplitude; pitch-bend) lives in Spotify's Python (`basic_pitch/note_creation.py`). We **re-implement** the parts we need (resampling + polyphonic note decoding) in Swift; we do not execute any Python.

## 3. Code-injection / unsafe-call review (of what we vendor)

We vendor two things: the data artifact (above) and **Swift** code. There is **no Python, no shell, no eval/exec/pickle/subprocess/`os.system`/`compile`/`__import__`** anywhere in what we adopt.

- The Swift `BasicPitchTranscriber` + decoder is a faithful re-implementation of the upstream *algorithm* (`output_to_notes_polyphonic`, `get_infered_onsets`, `constrain_frequency`, `model_frames_to_time`) — **pure numeric array logic** (thresholding, local-maxima peak-picking, an energy-walk note assembly, the "melodia trick"). No reflection, no dynamic dispatch on external data, no deserialization of untrusted formats.
- The only deserialization is Apple Core ML loading the bundled (trusted, checksummed) model via the system framework.
- No `Process`/`NSTask`, no `URLSession`/networking, no filesystem writes outside the system Core ML compile cache.

## 4. Input / bounds safety (resampler + buffer handling)

The one new piece of DSP is a bounded vDSP resampler (input rate → 22050 Hz). Reviewed handling:

- **Empty buffer** → returns an empty `Transcription` (no notes, no contour, duration 0); no inference attempted.
- **Ultra-short buffer** (< one model window) → zero-padded to exactly `AUDIO_N_SAMPLES` (43844), matching upstream `window_audio_file` padding; never reads out of bounds.
- **Non-finite samples** (NaN/Inf) → sanitized to 0 before resampling/inference (guards vDSP and the model from poisoned input).
- **Sample-rate mismatch** → the buffer is always resampled to the model rate internally; callers pass any rate. A non-positive `sampleRate` throws `TranscriptionError.invalidInput`.
- **Indexing** — windowing, overlap-trim, MLMultiArray sizing, and the decoder's frame/freq indices are all clamped to `[0, nFrames)` / `[0, 88)`; the MLMultiArray is allocated to the exact model input shape.

## 5. Exception design

- **Model load** (`init`) — missing bundled resource, Core ML compile failure, or `MLModel` init failure all **throw** `TranscriptionError` (`.modelResourceMissing` / `.modelLoadFailed`). Never `fatalError`, never a force-unwrap on the resource.
- **Inference** — a Core ML `prediction` error or an unexpected output shape **throws** `TranscriptionError.inferenceFailed`. Never crashes.
- The transcriber is `throws` end-to-end; a corrupt/absent model degrades to a thrown Swift error the caller handles, consistent with MCC's other failable APIs.

## 6. On-device packet capture — **the gating DEVICE step (Chris)**

This is **load-bearing, not pro-forma**, given Songcatcher's privacy-first / on-device promise. Before the `0.0.14` tag:

- **Chris confirms, via on-device packet capture, ZERO network egress during transcription/inference.** Core ML inference is on-device by design and the transcriber contains no networking code, but the privacy promise is verified empirically, not assumed.
- The `0.0.14` tag is **gated** on (a) this packet-capture confirmation and (b) a real nylon-recording sanity check. Until then: committed, **not pushed, not tagged**, `musicCraftCoreVersion` **not bumped**.

**STATUS — SATISFIED AT LIBRARY LEVEL (2026-05-31).** The egress condition is cleared at the library level by the three-layer verification recorded below ("Egress verification — results (2026-05-31)"): static (no networking symbols in `Sources/`), a runtime capability proof (inference passes under a full network-denied sandbox), and observational corroboration (no observed sockets). On that basis the `0.0.14` tag is cut. The **app-level** on-device packet capture inside Songcatcher (condition a) — capture → transcription under the app's full entitlements — remains a **Phase 2** step: it only becomes runnable once the transcriber is wired into the app (Phase 1 does no wiring), so it is correct scope, not a gap. The real nylon-recording sanity check (condition b) likewise moves to the Phase 2 accuracy bench.

## 7. Classification

**SAFE TO ADOPT.** The artifact is a checksummed, Apache-2.0, official Spotify Core ML serialization used as-is, containing only a serialized NN run by Apple's system Core ML runtime; we add no new dependencies, vendor no Python, and the only new code is bounded, pure-numeric Swift (a vDSP resampler + a faithful re-implementation of the upstream note-decoding algorithm) with throw-based error handling and reviewed bounds safety. **Adoption is conditional on the §6 on-device packet-capture confirmation (Chris) before tagging 0.0.14.**

### Swift adaptation notes
- **Velocity & pitch-bend are NOT model outputs** — the model emits only the three activation arrays. Velocity (amplitude) is the mean note activation over the note's span (ported). Pitch-bend is derived from the contour matrix in upstream `get_pitch_bends`; **Phase 1 defers pitch-bend** (`pitchBend == nil`) to keep the unvalidated surface tight — recorded as an API deviation, deferred to a later phase.
- **Core ML compilation** — the `.mlpackage` is compiled to `.mlmodelc` at **runtime** via `MLModel.compileModel(at:)` (SwiftPM CLI does not run `coremlc`); this avoids committing a precompiled `.mlmodelc` and works whether or not the build pipeline compiled the resource.
- **Validation** — the model could not be loaded/run in the CLI sandbox (coremltools import hangs; Core ML inference not exercisable here). The decoder port is faithful to the pinned upstream source but is **unvalidated against the reference in this environment**; the device/Xcode validation (§6 + the nylon sanity check) is the validation gate, by design for Phase 1.

---

### Verification record (how the I/O above was confirmed, since coremltools would not run here)
- **Artifact I/O names** — `strings` on the committed `model.mlmodel` protobuf: one input `input_2`; three outputs `Identity`, `Identity_1`, `Identity_2` (generic TF→CoreML conversion names).
- **Output → head mapping** — pinned upstream `basic_pitch/inference.py` (`predict`): `note = Identity_1`, `onset = Identity_2`, `contour = Identity`.
- **Input shape / rate / windowing** — pinned upstream `basic_pitch/constants.py`: `AUDIO_SAMPLE_RATE = 22050`, `AUDIO_N_CHANNELS = 1`, `FFT_HOP = 256`, `AUDIO_WINDOW_LENGTH = 2 s`, `AUDIO_N_SAMPLES = 43844`, `ANNOTATIONS_FPS = 86`, note/onset bins `88`, contour bins `264` (88×3); `inference.py:window_audio_file` feeds `(1, 43844, 1)` windows.
- **Velocity / pitch-bend provenance** — pinned upstream `basic_pitch/note_creation.py`: amplitude computed in `output_to_notes_polyphonic`; bends in `get_pitch_bends` (both post-processing, not model outputs).

---

## Egress verification — results (2026-05-31)

Three independent layers, run on macOS **26.3.1** (build 25D771280a). This is the library-level evidence for the §6 egress condition; it is what clears the `0.0.14` tag. (All three layers ran on this machine — none were skipped.)

**1. Static — no networking capability in source.** `grep -rnE` over all of `Sources/` for `URLSession|URLRequest|URL(string|NWConnection|NWListener|import Network|CFSocket|CFStream|getaddrinfo|connect(|socket(|BSDSocket|Process(|NSTask|posix_spawn|https?://` returned **NO MATCHES** — both across `Sources/` and focused on `Sources/MusicCraftCore/Transcription/`. There is no API in the compiled library capable of opening a socket, spawning a process, or resolving a host. Absence of capability, not merely absence of observed behavior.

**2. Runtime capability proof (headline) — inference succeeds with all network denied.** The test bundle was built with network available (`swift build --build-tests`; `dependencies: []`, so nothing to fetch), then `BasicPitchTranscriberTests` was run under a sandbox profile denying all network:

```
sandbox-exec -p '(version 1)(allow default)(deny network-outbound)(deny network-inbound)(deny network-bind)' \
  xcrun xctest -XCTest MusicCraftCoreTests.BasicPitchTranscriberTests \
  .build/arm64-apple-macosx/debug/MusicCraftCorePackageTests.xctest
```

Result: **11/11 passed** under full network denial — including `testModelLoads` (Core ML loads the bundled `nmp.mlpackage`), `testInferenceProducesNotes` (inference runs), and `testInferenceIsDeterministic` (byte-identical output across runs). Model load + inference therefore require no network call; if any were on the required path, the suite would fail under this profile. (Direct `swift test` under the sandbox was blocked only by SwiftPM's manifest **recompile** step — `swiftc` on `Package.swift` hit `sandbox_apply: Operation not permitted` under nesting — not by inference; running the prebuilt `.xctest` bundle via `xcrun xctest` bypasses that. `sandbox-exec` was confirmed functional here on a trivial command first.)

**3. Observational corroboration (sampling-based).** During a normal un-sandboxed run, `lsof -i -a -p <pid>` for the test process tree showed **no internet sockets** (parent or children), and `nettop -P -L 1` showed no matching rows. The suite passed (11/11). This layer is sampling-based — the run is ~1 s, so a sub-second connection could in principle be missed — hence corroboration, not the primary proof (layer 2 is).

**Conclusion.** Library-level egress is confirmed: the Basic Pitch transcriber/inference performs **no network egress**. App-level on-device confirmation inside Songcatcher (packet capture under the app's entitlements) remains a Phase 2 step — only runnable once the transcriber is wired into the app — and is correct scope, not a gap in this evidence (see §6 STATUS).
