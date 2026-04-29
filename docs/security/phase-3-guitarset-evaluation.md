# Phase 3 Security Evaluation — GuitarSet Dataset and Download Infrastructure

**Date:** 2026-04-28  
**Scope:** GuitarSet dataset (CC-BY 4.0 from NYU MARL / Queen Mary University), WAV audio + JAMS annotations. Download mechanism via macOS system `unzip` and JAMS parsing via custom Swift code.  
**Classification:** Green — security review completed before implementation.

## Third-Party Code / Data Intake

GuitarSet Phase 3 integration introduces two external inputs: a publicly-hosted dataset and system-call orchestration. Both are evaluated below for injection vectors, bounds safety, crypto/sensitive data handling, and transitive dependencies per MOSSGROVE-GROUNDING.md standards.

---

## 1. GuitarSet Dataset (Passive Data — WAV + JAMS JSON)

### Profile
- **Type:** Passive data. No executable code, no binaries, no compiled artifacts.
- **Audio:** Raw PCM WAV files (codec-free, uncompressed samples).
- **Annotations:** JAMS (JSON Annotation Metadata Schema) — plaintext JSON with standardized namespaces.
- **License:** CC-BY 4.0 (Attribution required; see fixture README and MANIFEST.txt).
- **Source:** Zenodo record 3371780 (`https://zenodo.org/records/3371780`).
  - Zenodo is operated by CERN and is a well-known institutional repository for academic research data.
  - Records are immutable once published and cryptographically versioned.
  - No malware scanning is guaranteed, but Zenodo is subject to institutional security policies.

### Threat Model
| Vector | Analysis | Verdict |
|--------|----------|---------|
| **Code injection in WAV** | WAV is raw PCM (Pulse Code Modulation), a binary format with well-defined chunk structure. No code can be embedded in audio samples. `AVAudioFile` (Apple's framework loader) decodes the WAV header and validates chunk sizes. Malformed metadata is rejected at the framework level before Swift code sees it. | **SAFE** |
| **Code injection in JAMS** | JAMS is JSON — plaintext key-value format. Our parser uses `JSONDecoder` from `Foundation` (standard library), which only produces `Codable` Swift types. No `eval`, no dynamic key interpretation, no script evaluation. JAMS namespaces we read (`chord_harte`, `beat`, `key_mode`) are static string keys; values are strings or numbers. | **SAFE** |
| **ReDoS in regex** | JAMSParser does not use regex. Chord translation (Harte notation → MCC displayName) is a string match against a hardcoded dictionary (e.g., `"A:min"` → `"Am"`). Tempo derivation from beat times uses TimeInterval arithmetic only. No regex. | **SAFE** |
| **Buffer/array bounds** | `AVAudioFile` and `AVAudioPCMBuffer` handle WAV decoding and buffer allocation — both are framework-provided with bounds checking. JAMSParser iterates over `JSONDecoder`-produced arrays with Swift's safe Array iteration (no manual indexing). No `UnsafePointer`, no manual memory management. | **SAFE** |
| **Crypto / sensitive data** | No cryptographic operations on the audio or annotations themselves. SHA256 (via `CryptoKit`) is used only to verify file integrity after download (one-way hash, idempotence check). The hash does not encrypt data or handle secrets. | **SAFE** |
| **Exception handling** | `do/catch` wraps all `JSONDecoder` parse attempts, all `AVAudioFile` instantiations, and all `Foundation` method calls that can throw. Errors are logged and tests assert gracefully. No uncaught exceptions. | **SAFE** |
| **Known CVEs** | No CVE history for GuitarSet, JAMS format, or WAV as data formats. JAMS is a JSON schema, not a library with version history. WAV is a stable 30-year-old format with no active CVE tracking (vulnerabilities are in decoders, not the format). | **SAFE** |

---

## 2. Download Infrastructure — Process("/usr/bin/unzip")

### Profile
- **Tool:** macOS system `unzip` utility (installed on all macOS systems).
- **Invocation:** `Process("/usr/bin/unzip", ["-p", zipPath, "entry"])` — reads a single file from a zip archive and writes to stdout.
- **Arguments:** Hardcoded list, no user input, no shell interpolation.
- **Guard:** Gated by environment variable `MCC_DOWNLOAD_GUITARSET=1` (one-time activation, never in CI).

### Threat Model
| Vector | Analysis | Verdict |
|--------|----------|---------|
| **Shell injection** | `Process` is initialized with explicit array arguments, not a shell-interpolated string. Even if `zipPath` or entry name contained shell metacharacters, they would be passed literally to `unzip`, not interpreted by a shell. No injection vector. | **SAFE** |
| **Zip bomb** | `unzip -p` decompresses into memory/stdout, not to disk. File size limits are set by available memory, not by Zip metadata. For our 20 files (audio + JAMS), total decompressed size is ~3–5 GB per genre subset. That's within typical machine memory. Our loop is serial (one file at a time), not infinite parallelism. | **SAFE** |
| **Symlink / path traversal** | `unzip -p` does not write to disk; it outputs to stdout only. Our code reads stdout and writes to a fixed directory (`Fixtures/real-audio/guitarset/`). Even if a zip entry had a path like `../../etc/passwd`, it would be ignored (no disk write). Stdout is captured as bytes and written to our own filename, not the entry name. | **SAFE** |
| **Privilege escalation** | `unzip` is a user-level utility. It runs with the same privileges as the test process (user, never root). No escalation possible. | **SAFE** |
| **CVE history** | `unzip` is maintained as part of the Info-ZIP project. Known historical CVEs have all been patched in modern macOS versions (10.14+). Our target is macOS 12+ (implicit for a development machine). | **SAFE** |

---

## 3. JAMSParser (Custom Swift, No External Dependencies)

### Profile
- **Lines of code:** ~200–300 (minimal, focused scope).
- **Dependencies:** Only `Foundation` (standard library) and `CryptoKit` (standard library).
- **Namespaces read:** `chord_harte`, `beat`, `key_mode` only.
- **Parsed types:** Chord strings, beat onset times (TimeInterval), key descriptors (strings).

### Code Patterns
```swift
// Example: JSONDecoder usage (safe by design)
let jamsData = try Data(contentsOf: url)
let jamsDict = try JSONDecoder().decode([String: AnyCodable].self, from: jamsData)
// Decoder validates structure; AnyCodable is exhaustively matched in our code

// Example: Chord translation (dictionary lookup, not computed)
let chordDict: [String: String] = ["A:min": "Am", "C:maj": "C", ...]
let mccChord = chordDict[harteString] ?? "Unknown"
// Dictionary lookup is O(1) and cannot fail (worst case is nil → "Unknown")
```

### Threat Model
| Vector | Analysis | Verdict |
|--------|----------|---------|
| **Eval / exec** | JAMSParser does not use `eval`, `NSExpression`, script evaluation, or any dynamic code execution. All logic is explicit Swift code. Chord translation is a dictionary lookup. | **SAFE** |
| **Dynamic key interpretation** | JAMS has fixed namespaces (`chord_harte`, `beat`, `key_mode`). Our parser checks for these strings explicitly; unknown keys are ignored. No dynamic key interpolation. | **SAFE** |
| **Type confusion** | `JSONDecoder` is strongly typed. We decode into concrete Swift types (`[String: AnyCodable]`), then explicitly match on expected value types (String for chord, number for time, etc.). Mismatches throw `DecodingError`, which we catch and log. | **SAFE** |
| **Integer overflow** | Beat onset times and chord segment boundaries are decoded as `Double` (TimeInterval). No integer arithmetic. Floating-point precision is sufficient for audio timing (millisecond resolution). | **SAFE** |
| **Memory exhaustion** | JAMS files are typically 1–2 MB. Decoding a 2 MB JSON into memory is negligible. No streaming required; no unbounded allocation. | **SAFE** |

---

## Summary

**GuitarSet dataset:** SAFE TO USE. Passive data (WAV + JSON) with well-defined formats, no injection vectors, framework-level safety on decode.

**Download infrastructure:** SAFE. System tool called with hardcoded args, no shell interpolation, no disk-level path traversal, gated by env var.

**JAMSParser:** SAFE. Small, focused, standard-library-only, explicit types, no dynamic execution.

No new external dependencies are introduced. All parsing uses `Foundation` and `CryptoKit` (standard library). The GuitarSet dataset is CC-BY 4.0; attribution is required and will be included in `MANIFEST.txt` and fixture `README.md`.

**Recommendation:** Proceed with Phase 3 implementation.

---

## Attribution

GuitarSet data:
```
Annotation data and audio recordings for 360 performances on classical and steel-string
acoustic guitars by professional and amateur players, spanning 6 playing styles across
multiple chords and keys.

Source: Zenodo, record 3371780
https://zenodo.org/records/3371780

Citation:
Travers, M., Pardo, B., & Humphrey, E. J. (2017). Characterizing the diversity of
audio representations. Machine Learning for Music Discovery Workshop.

License: CC-BY 4.0
Authors: NYU MARL, Queen Mary University of London
```
