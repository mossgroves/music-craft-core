# MCC Audio Analysis Testing Strategy

**Status:** Draft (pre-implementation)  
**Scope:** Chord detection, lyric transcription, note detection, tempo estimation, melody contour  
**Living in:** MCC/Tests/AudioAnalysis/

---

## 1. Test Fixtures (Audio Sources)

### 1.1 Synthetic Fixtures (Fast, Reproducible, Limited Scope)
**Purpose:** Baseline correctness, regression detection, edge cases.

**Generation approach:**
- AVAudioEngine (Swift) or librosa (Python helper script) to synthesize known chord progressions
- Parameters: root note, chord quality, octave, duration, sample rate (44.1kHz), voice (sine, triangle, harmonics)

**Test sets:**
```
synthetic/
  chords/
    all-major-triads.wav         // C, C#, D... B major across 3 octaves
    all-minor-triads.wav
    seventh-chords.wav           // Cmaj7, Cm7, C7, Cdim, Caug
    cadences.wav                 // I–IV–V–I, ii–V–I, etc. in multiple keys
    
  tempo/
    steady-80bpm.wav             // Metronome click
    steady-120bpm.wav
    steady-140bpm.wav
    
  notes/
    scale-ascending.wav          // C major scale, quarter notes
    arpeggios.wav                // C major arpeggio, various rhythms
    
  lyrics/
    synthetic-speech.wav         // TTS: "hello world testing one two three"
    
  contour/
    simple-melody.wav            // Single pitch, slow glissando, ascending scale
```

**Success criteria:**
- Chord detection: 100% accuracy (synthetic has no ambiguity)
- Tempo: exact match (beats-per-frame known)
- Notes: all detected with confidence ≥0.9
- Lyrics: perfect transcription (TTS input → transcribed output match)

---

### 1.2 Real-Audio Fixtures (Ground Truth, Representative)
**Purpose:** Real-world validation; instrument/vocal variation; audio quality issues.

**Sources (prioritized):**

#### Tier A: Acoustic Guitar (Your Taylor 812ce-n)
- **Why:** Target instrument from CLAUDE.md; weaker 3rd harmonics, stronger fundamental/5th
- **Samples needed:**
  - 4 basic chords (Am, F, C, G) — 8 seconds each, fingerpicking style
  - Em pentatonic progression (em–G–D–A) — 16 seconds
  - Barre chords (Fm, Bm) — to test accuracy on harder voicings
  - Tempo varies (60, 100, 120 bpm) — 8 bars each
  - Clean recording (quiet room, no noise)
  - Also: noisy recording (background traffic/fan) — to test robustness

**Annotation:** JAMS (JSON Annotatied Music Specification) format
```json
{
  "file": "guitar-am-f-c-g.m4a",
  "annotations": [
    {
      "namespace": "chord",
      "data": [
        {"time": 0.0, "duration": 2.0, "value": "Am"},
        {"time": 2.0, "duration": 2.0, "value": "F"},
        ...
      ]
    },
    {
      "namespace": "tempo",
      "data": [
        {"time": 0.0, "duration": 16.0, "value": 120}
      ]
    }
  ]
}
```

#### Tier B: Vocal Recordings (Test Lyric Extraction + Contour)
- **Samples:** Hummed melodies, sung lyrics, spoken words
- **Variants:** Clean, noisy, compressed (mobile recording)
- **Annotation:** Word-level timestamps + contour pitch grid

#### Tier C: Public Datasets (Optional, Validation)
- **MIREX datasets** (chord estimation challenge audio)
- **Beatles song snippets** (widely annotated, free to use)
- **Spotify AI covers** (chord-labeled)
- **Note:** Use sparingly; licensing matters. Start with your own.

**Storage:** `MCC/Tests/AudioAnalysis/fixtures/`
```
fixtures/
  synthetic/
    chords/
    tempo/
    notes/
  real-audio/
    guitar/
      am-f-c-g-clean.m4a
      am-f-c-g-clean.jams  (ground truth)
      em-progression-120bpm.m4a
      em-progression-120bpm.jams
    vocal/
      hummed-melody.m4a
      hummed-melody.jams
  public/
    (None yet; optional later)
```

---

## 2. Test Harness Architecture

### 2.1 Test Structure
```swift
// MCC/Tests/AudioAnalysis/ChordDetectionTests.swift

class ChordDetectionTests: XCTestCase {
    
    var fixtureLoader: AudioFixtureLoader!
    var metricsCollector: AudioAnalysisMetrics!
    
    override func setUp() {
        fixtureLoader = AudioFixtureLoader(bundlePath: "fixtures")
        metricsCollector = AudioAnalysisMetrics()
    }
    
    // SYNTHETIC: Fast, deterministic
    func testSyntheticAllMajorTriads() throws {
        let audio = try fixtureLoader.loadSynthetic("chords/all-major-triads.wav")
        let result = try AudioExtractor.extract(buffer: audio.buffer, sampleRate: audio.sampleRate)
        
        let expected = ["C", "C♯", "D", "D♯", "E", "F", ...] // 36 major triads
        let detected = result.chordSegments.map { $0.chord.displayName }
        
        XCTAssertEqual(detected, expected, "Major triads must detect with 100% accuracy")
    }
    
    // REAL-AUDIO: Ground truth comparison
    func testRealAudioGuitarAmFCG() throws {
        let fixture = try fixtureLoader.loadRealAudio("guitar/am-f-c-g-clean.m4a")
        let groundTruth = try JAMSLoader.load(fixture.jamspath) // Load JAMS annotations
        
        let result = try AudioExtractor.extract(buffer: fixture.buffer, sampleRate: fixture.sampleRate)
        
        let metrics = AudioAnalysisMetrics.compareChords(
            detected: result.chordSegments,
            groundTruth: groundTruth.chords,
            toleranceSeconds: 0.2  // Allow 200ms timing deviation
        )
        
        metricsCollector.recordChordTest(fixture: "am-f-c-g-clean", metrics: metrics)
        
        // Success criteria
        XCTAssertGreaterThanOrEqual(metrics.rootAccuracy, 0.95, "Root accuracy ≥95%")
        XCTAssertGreaterThanOrEqual(metrics.qualityAccuracy, 0.90, "Quality accuracy ≥90%")
        XCTAssertGreaterThanOrEqual(metrics.confidenceAverage, 0.85, "Avg confidence ≥0.85")
    }
    
    // EDGE CASE: Noisy real-world
    func testRealAudioGuitarNoisy() throws {
        let fixture = try fixtureLoader.loadRealAudio("guitar/am-f-c-g-noisy.m4a")
        let groundTruth = try JAMSLoader.load(fixture.jamspath)
        
        let result = try AudioExtractor.extract(buffer: fixture.buffer, sampleRate: fixture.sampleRate)
        let metrics = AudioAnalysisMetrics.compareChords(detected: result.chordSegments, groundTruth: groundTruth.chords)
        
        metricsCollector.recordChordTest(fixture: "am-f-c-g-noisy", metrics: metrics)
        
        // Noisier audio allows lower thresholds
        XCTAssertGreaterThanOrEqual(metrics.rootAccuracy, 0.85, "Root accuracy ≥85% (noisy)")
        XCTAssertGreaterThanOrEqual(metrics.qualityAccuracy, 0.75, "Quality accuracy ≥75% (noisy)")
    }
}
```

### 2.2 Metrics Collection

Define what "accurate" means for each subsystem:

**Chord Detection Metrics:**
- `rootAccuracy`: % of detected chords with correct root (C vs. C#, but C major vs. C minor is OK)
- `qualityAccuracy`: % of detected chords with correct quality (major vs. minor, 7th, etc.)
- `fullAccuracy`: % of detected chords matching exactly (root + quality)
- `confidenceAverage`: mean confidence score across all detected chords
- `timingDeviation`: seconds of offset between detected chord boundary and ground truth boundary
- `falsePositives`: chords detected where none existed (silence)
- `falsNegatives`: chords missed (ground truth chord not detected)

**Lyric Transcription Metrics:**
- `wordAccuracy`: % of transcribed words matching ground truth (case-insensitive)
- `characterErrorRate`: Levenshtein distance / total characters
- `timingAccuracy`: % of word boundaries within ±100ms of ground truth
- `confidenceAverage`: mean confidence per word

**Tempo Estimation Metrics:**
- `tempoError`: |detected BPM - ground truth BPM| / ground truth BPM (%)
- `confidenceScore`: TempoEstimator confidence value (0–1)
- `rankedPosition`: position of ground truth tempo in the ranked candidate list (1 = first/best)

**Note Detection Metrics:**
- `recall`: % of ground truth notes detected
- `precision`: % of detected notes that are correct (no false positives)
- `pitchAccuracy`: % of notes within ±1 semitone of ground truth
- `onsetAccuracy`: % of note onsets within ±50ms of ground truth

**Contour Metrics:**
- `pitchTracking`: % of frames with detected pitch within ±2 semitones
- `energyCorrelation`: Pearson correlation between detected and ground truth pitch contour

---

## 3. Test Runner & Results Reporting

### 3.1 Test Execution
```bash
# Run all audio analysis tests
xcodebuild test -scheme MusicCraftCore -destination 'platform=iOS Simulator' \
  -only-testing MusicCraftCoreTests/AudioAnalysisTests

# Generate detailed report
xcodebuild test ... -resultBundlePath ./test-results.xcresult
xcrun xcresulttool get --format json ./test-results.xcresult > results.json
```

### 3.2 Results Reporting (Markdown + JSON)

**HTML Report** (for human review):
```
AudioAnalysisTests_2026-04-28.html
├─ Test Summary (pass/fail count, overall score)
├─ Chord Detection
│  ├─ Synthetic: ✅ 100% (all-major-triads, etc.)
│  ├─ Real-Audio: 
│  │  ├─ am-f-c-g-clean: 96% root, 92% quality → ✅ PASS
│  │  ├─ am-f-c-g-noisy: 84% root, 73% quality → ⚠️ WARN (below threshold)
│  │  └─ em-progression: 91% root, 88% quality → ✅ PASS
│  └─ Regression: No regressions vs. last run
├─ Tempo Estimation
│  ├─ Synthetic: ✅ 100% (exact BPM match)
│  ├─ Real-Audio:
│  │  ├─ guitar-80bpm: Error 3% → ✅ PASS
│  │  ├─ guitar-120bpm: Error 2% → ✅ PASS
│  └─ Regression: ✅ No regressions
└─ Summary: 18/20 tests passed, 1 warning (noisy audio)
```

**JSON Results** (for programmatic tracking):
```json
{
  "testRunID": "audio-analysis-2026-04-28-105400",
  "timestamp": "2026-04-28T10:54:00Z",
  "mcVersion": "0.0.9",
  "tests": [
    {
      "name": "chord-detection-real-audio-am-f-c-g-clean",
      "status": "pass",
      "metrics": {
        "rootAccuracy": 0.96,
        "qualityAccuracy": 0.92,
        "timingDeviation": 0.08,
        "confidenceAverage": 0.87
      },
      "thresholds": {
        "rootAccuracy": 0.95,
        "qualityAccuracy": 0.90
      }
    },
    ...
  ],
  "summary": {
    "totalTests": 20,
    "passed": 18,
    "warned": 1,
    "failed": 1,
    "regressions": 0
  }
}
```

---

## 4. Features to Test (Priority)

| Feature | Test Type | Ground Truth | Success Criteria | Blocker? |
|---------|-----------|--------------|------------------|----------|
| **Chord Detection** | Synthetic + Real | JAMS chord annotations | Root ≥95%, Quality ≥90% | YES — blocks voicings |
| **Tempo Estimation** | Synthetic + Real | Metronome / manual annotation | Error ≤5% | YES — affects playback sync |
| **Note Detection** | Synthetic | Known frequencies | Recall ≥90%, Precision ≥85% | Medium — for contour |
| **Lyric Transcription** | Real audio | Manual transcription | Word accuracy ≥85% | YES — for "transcribed in margin" |
| **Melody Contour** | Real audio | Pitch grid / reference recordings | Pitch tracking ≥80% | Low — Phase C+ feature |
| **Key Inference** | Real audio | Manual analysis (music theory) | Matches human judgment ≥80% | Medium — for search |

---

## 5. Implementation Plan

### Phase 1: Infrastructure (Week 1)
- [ ] Create AudioFixtureLoader (load .m4a, .wav, JAMS annotations)
- [ ] Define AudioAnalysisMetrics struct (above metrics)
- [ ] Add synthetic fixture generation helper
- [ ] Implement Xcode test templates

### Phase 2: Synthetic Fixtures (Week 1)
- [ ] Generate all-major-triads.wav, etc.
- [ ] Write synthetic chord detection tests
- [ ] Write synthetic tempo tests
- [ ] Establish baseline (should be 100% pass)

### Phase 3: Real-Audio Fixtures (Week 2)
- [ ] Record your guitar (Am F C G, Em progression, tempo variants, noisy variant)
- [ ] Annotate with JAMS
- [ ] Record vocal samples (hummed melody, spoken lyrics)
- [ ] Write real-audio chord tests
- [ ] Establish baselines and success thresholds

### Phase 4: Reporting & CI Integration (Week 2)
- [ ] Implement HTML/JSON report generation
- [ ] Add to GitHub Actions (run tests on every commit)
- [ ] Dashboard: trends over time (regression detection)
- [ ] Slack integration: notify on failures

### Phase 5: Lyric & Other Features (Week 3)
- [ ] Add LyricsExtractor tests (use TTS + real vocal)
- [ ] Add note detection, contour tests
- [ ] Baseline all features
- [ ] Document success criteria per feature

---

## 6. Living in Sanctuary

**Device test integration:**
- After each Sanctuary audio capture, optionally save to `./device-test-captures/`
- Compare against fixture ground truth in post-hoc analysis
- Build a device-test validation loop: "Does this real device recording match expectations?"

**Example device test harness:**
```swift
// SanctuaryTests/AudioAnalysisIntegrationTests.swift
func testFragmentAnalyzerWithKnownAudio() throws {
    // Load guitar fixture
    let fixture = try fixtureLoader.loadRealAudio("guitar/am-f-c-g-clean.m4a")
    
    // Create fragment with this audio
    let fragment = Fragment(primaryKind: .audio, audio: AudioModality(takes: [Take(audioAsset: fixture.url)]))
    
    // Run Sanctuary's MCCAnalyzer
    let analyzer = MCCAnalyzer()
    let result = try await analyzer.analyze(fragment)
    
    // Verify against fixture ground truth
    let metrics = AudioAnalysisMetrics.compareChords(
        detected: result.audioAnalysis!.chordSegments,
        groundTruth: fixture.groundTruth.chords
    )
    
    XCTAssertGreaterThanOrEqual(metrics.rootAccuracy, 0.95)
}
```

---

## 7. Success Criteria for This Framework

1. ✅ Chord detection: ≥95% root accuracy on clean audio, ≥85% on noisy
2. ✅ Tempo: ≤5% BPM error
3. ✅ Lyric transcription: ≥85% word accuracy
4. ✅ All tests run in CI/CD (no manual intervention)
5. ✅ Regressions detected automatically
6. ✅ Device tests can validate against fixtures
7. ✅ Clear pass/fail criteria; no subjective judgments
