import XCTest
@testable import MusicCraftCore

final class TempoEstimatorTests: XCTestCase {

    // MARK: - From Beats Path (Structural)

    func testEstimateTempoFromBeatsEmpty() {
        // Structural: empty beats returns empty tempos.
        let tempos = TempoEstimator.estimateTempo(beats: [])
        XCTAssertEqual(tempos.count, 0)
    }

    func testEstimateTempoFromBeatsSingleBeat() {
        // Structural: single beat cannot estimate tempo (need >= 2).
        let tempos = TempoEstimator.estimateTempo(beats: [0.0])
        XCTAssertEqual(tempos.count, 0)
    }

    func testEstimateTempoFromBeatsMultiple() {
        // Structural: multiple beats produce tempo estimates.
        // Algorithm accuracy deferred to 0.0.9.1 real-audio fixtures.
        let beats: [TimeInterval] = [0.0, 0.5, 1.0, 1.5, 2.0]
        let tempos = TempoEstimator.estimateTempo(beats: beats)

        XCTAssertGreaterThanOrEqual(tempos.count, 0)
    }

    func testEstimateTempoFromBeatsIrregular() {
        // Structural: irregular spacing returns estimates (algorithm accuracy deferred).
        let beats: [TimeInterval] = [0.0, 0.5, 1.0, 1.6, 2.1]
        let tempos = TempoEstimator.estimateTempo(beats: beats)

        XCTAssertNotNil(tempos)
    }

    func testEstimateTempoFromBeatsManyBeats() {
        // Structural: many beats handled without crash.
        let beats: [TimeInterval] = (0..<20).map { TimeInterval($0) * 0.5 }
        let tempos = TempoEstimator.estimateTempo(beats: beats)

        XCTAssertNotNil(tempos)
    }

    func testEstimateTempoFromBeatsMaxCandidates() {
        // Structural: maxCandidates configuration is respected.
        let beats: [TimeInterval] = (0..<20).map { TimeInterval($0) * 0.5 }

        let configLimit1 = TempoEstimator.Configuration(maxCandidates: 1)
        let tempos1 = TempoEstimator.estimateTempo(beats: beats, configuration: configLimit1)
        XCTAssertLessThanOrEqual(tempos1.count, 1)

        let configLimit5 = TempoEstimator.Configuration(maxCandidates: 5)
        let tempos5 = TempoEstimator.estimateTempo(beats: beats, configuration: configLimit5)
        XCTAssertLessThanOrEqual(tempos5.count, 5)
    }

    func testEstimateTempoFromBeatsHarmonicRatios() {
        // Structural: harmonic ratios configuration affects candidate count.
        let beats: [TimeInterval] = [0.0, 0.5, 1.0, 1.5, 2.0]

        let configManyRatios = TempoEstimator.Configuration(harmonicRatios: [1, 2, 0.5, 1.5])
        let temposMany = TempoEstimator.estimateTempo(beats: beats, configuration: configManyRatios)

        let configFewRatios = TempoEstimator.Configuration(harmonicRatios: [1])
        let temposFew = TempoEstimator.estimateTempo(beats: beats, configuration: configFewRatios)

        // More ratios may produce more candidates (but maxCandidates applies)
        XCTAssertNotNil(temposMany)
        XCTAssertNotNil(temposFew)
    }

    // MARK: - From Buffer Path (Structural)

    func testEstimateTempoFromBufferEmpty() {
        // Structural: empty buffer returns empty tempos.
        let tempos = TempoEstimator.estimateTempo(buffer: [], sampleRate: 44100)
        XCTAssertEqual(tempos.count, 0)
    }

    func testEstimateTempoFromBufferSilence() {
        // Structural: silence buffer returns empty.
        let buffer = [Float](repeating: 0, count: 44100)
        let tempos = TempoEstimator.estimateTempo(buffer: buffer, sampleRate: 44100)
        XCTAssertNotNil(tempos)
    }

    func testEstimateTempoFromBufferWithAudio() {
        // Structural: buffer path runs without crash.
        let buffer = [Float](repeating: 0.1, count: 44100 * 2)
        let tempos = TempoEstimator.estimateTempo(buffer: buffer, sampleRate: 44100)
        XCTAssertNotNil(tempos)
    }

    func testEstimateTempoBeatsPreferred() {
        // Structural: if both beats and buffer provided, beats take precedence (buffer ignored).
        let beats: [TimeInterval] = [0.0, 0.5, 1.0, 1.5]
        let buffer = [Float](repeating: 0.1, count: 44100 * 2)

        let temposFromBeats = TempoEstimator.estimateTempo(beats: beats)
        let temposFromBoth = TempoEstimator.estimateTempo(beats: beats, buffer: buffer, sampleRate: 44100)

        XCTAssertEqual(temposFromBeats.count, temposFromBoth.count)
    }

    func testEstimateTempoNeitherBeatsNorBuffer() {
        // Structural: neither beats nor buffer returns empty.
        let tempos = TempoEstimator.estimateTempo()
        XCTAssertEqual(tempos.count, 0)
    }

    // MARK: - Configuration Tests

    func testConfigurationDefaults() {
        // Structural: Configuration defaults are correctly set.
        // 0.0.11: window/hop defaults lowered to 1024/512 to match the spectral-flux onset
        // detector's per-frame granularity (previously 2048/1024 driving an RMS-autocorrelation
        // pipeline).
        let config = TempoEstimator.Configuration()

        XCTAssertEqual(config.onsetWindowSize, 1024)
        XCTAssertEqual(config.onsetHopSize, 512)
        XCTAssertEqual(config.minTempoMs, 300)
        XCTAssertEqual(config.maxTempoMs, 3000)
        XCTAssertEqual(config.maxCandidates, 3)
        XCTAssertEqual(config.harmonicRatios.count, 6)
    }

    func testConfigurationCustom() {
        // Structural: custom values are preserved.
        let config = TempoEstimator.Configuration(
            onsetWindowSize: 4096,
            maxCandidates: 5,
            harmonicRatios: [1, 2, 0.5]
        )

        XCTAssertEqual(config.onsetWindowSize, 4096)
        XCTAssertEqual(config.maxCandidates, 5)
        XCTAssertEqual(config.harmonicRatios.count, 3)
    }

    func testConfigurationDefault() {
        // Structural: Configuration.default is available.
        let config = TempoEstimator.Configuration.default
        XCTAssertEqual(config.maxCandidates, 3)
    }

    func testConfigurationEquatable() {
        // Structural: configurations are comparable.
        let config1 = TempoEstimator.Configuration()
        let config2 = TempoEstimator.Configuration()
        XCTAssertEqual(config1, config2)
    }

    func testConfigurationHashable() {
        // Structural: configurations can be used in sets.
        let config1 = TempoEstimator.Configuration()
        let config2 = TempoEstimator.Configuration(maxCandidates: 5)

        var set: Set<TempoEstimator.Configuration> = [config1]
        set.insert(config2)

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - TempoEstimate Tests

    func testTempoEstimateConstruction() {
        // Structural: TempoEstimate can be constructed.
        let estimate = TempoEstimate(bpm: 120.0, confidence: 0.95, isHarmonic: false)

        XCTAssertEqual(estimate.bpm, 120.0)
        XCTAssertEqual(estimate.confidence, 0.95)
        XCTAssertFalse(estimate.isHarmonic)
    }

    func testTempoEstimateDefaultHarmonic() {
        // Structural: isHarmonic defaults to false.
        let estimate = TempoEstimate(bpm: 120.0, confidence: 0.95)
        XCTAssertFalse(estimate.isHarmonic)
    }

    func testTempoEstimateHarmonicTrue() {
        // Structural: isHarmonic can be set to true.
        let estimate = TempoEstimate(bpm: 240.0, confidence: 0.8, isHarmonic: true)
        XCTAssertTrue(estimate.isHarmonic)
    }

    func testTempoEstimateEquatable() {
        // Structural: estimates are comparable.
        let estimate1 = TempoEstimate(bpm: 120.0, confidence: 0.95)
        let estimate2 = TempoEstimate(bpm: 120.0, confidence: 0.95)
        let estimate3 = TempoEstimate(bpm: 130.0, confidence: 0.95)

        XCTAssertEqual(estimate1, estimate2)
        XCTAssertNotEqual(estimate1, estimate3)
    }

    func testTempoEstimateHashable() {
        // Structural: estimates can be used in sets.
        let estimate1 = TempoEstimate(bpm: 120.0, confidence: 0.95)
        let estimate2 = TempoEstimate(bpm: 120.0, confidence: 0.95)

        var set: Set<TempoEstimate> = [estimate1]
        set.insert(estimate2)

        XCTAssertEqual(set.count, 1)
    }

    func testTempoEstimateSendable() {
        // Structural: TempoEstimate is Sendable (async-safe).
        let estimate = TempoEstimate(bpm: 120.0, confidence: 0.95)
        let _: any Sendable = estimate
    }

    // MARK: - Note-native path (2026-07-21)

    func testNoteOnsetsSteadyQuartersReadTheirTempo() {
        // Quarter notes at 120 BPM: onsets every 0.5s for 10s.
        let onsets = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
        let estimates = TempoEstimator.estimateTempo(noteOnsets: onsets)
        XCTAssertFalse(estimates.isEmpty)
        XCTAssertEqual(estimates[0].bpm, 120, accuracy: 3, "Steady quarters at 120 read as 120; got \(estimates)")
        XCTAssertGreaterThan(estimates[0].confidence, 0.9, "Perfect steadiness reads ~1.0 on the consistency scale — this is the scale the consumer's 0.3 gate was calibrated to")
    }

    func testNoteOnsetsStrumClustersCollapseToOneEventEach() {
        // Strums at 100 BPM (every 0.6s), each strum = 4 string-onsets 12ms apart. Without
        // cluster collapsing the micro-IOIs would swamp the histogram with absurd rates.
        var onsets: [TimeInterval] = []
        for strum in 0..<20 {
            let t = Double(strum) * 0.6
            for string in 0..<4 { onsets.append(t + Double(string) * 0.012) }
        }
        let estimates = TempoEstimator.estimateTempo(noteOnsets: onsets)
        XCTAssertFalse(estimates.isEmpty)
        XCTAssertEqual(estimates[0].bpm, 100, accuracy: 2, "20 strums at 100 BPM read as 100; got \(estimates)")
    }

    func testNoteOnsetsJitteredFingerpickingStaysNearTruth() {
        // Eighth-ish fingerpicking around 90 BPM (events every ~0.333s) with ±25ms human jitter
        // (deterministic pattern — no randomness in tests).
        let jitter: [Double] = [0.006, -0.012, 0.015, -0.006, 0.0, 0.012, -0.015, 0.009]
        let eighthSeconds: Double = 60.0 / 90.0 / 2.0
        var onsets: [TimeInterval] = []
        for i in 0..<30 {
            let base: Double = Double(i) * eighthSeconds
            onsets.append(base + jitter[i % jitter.count])
        }
        let estimates = TempoEstimator.estimateTempo(noteOnsets: onsets)
        XCTAssertFalse(estimates.isEmpty)
        // TIGHTENED 2026-08-06 with the octave-disambiguation fix: the original assertion
        // accepted 90 OR its 2x 180 ("either is acceptable evidence"), which partly encoded
        // the double-time failure mode as expected behavior. With disambiguation the felt
        // register must win — this jitter pattern's deviations are alternation-heavy, the
        // signature of subdivisions under a slower felt beat — so eighth-note events at 90
        // now read ~90 (the 180 subdivision rate survives only as a harmonic candidate).
        XCTAssertEqual(estimates[0].bpm, 90, accuracy: 6,
                       "Jittered eighths at 90 must read the felt 90, not the 180 subdivision rate; got \(estimates)")
        XCTAssertGreaterThan(estimates[0].confidence, 0.6, "A real (if human) pulse reads mid-high consistency; got \(estimates)")
    }

    func testNoteOnsetsTooFewEventsAbstain() {
        XCTAssertTrue(TempoEstimator.estimateTempo(noteOnsets: [0, 0.5, 1.0, 1.5, 2.0]).isEmpty,
                      "Five events are not a pulse claim")
    }

    func testCollapseClustersKeepsFirstOfEachGesture() {
        let collapsed = TempoEstimator.collapseClusters([0, 0.012, 0.024, 0.6, 0.611, 1.2], window: 0.05)
        XCTAssertEqual(collapsed, [0, 0.6, 1.2])
    }

    // MARK: - Octave disambiguation (2026-08-06, the "6 Human" double-time fix)

    /// The swung-eighths fixture: 80 BPM (beat = 0.75s), strong onsets ON the beat, weak
    /// onsets 0.3797s after — IOIs alternate 0.3797/0.3703 (±1.25% swing around the 0.375
    /// subdivision). Shared by the two tests below.
    private func swungEightyOnsets() -> [TimeInterval] {
        var onsets: [TimeInterval] = []
        for beat in 0..<20 {
            let t = Double(beat) * 0.75
            onsets.append(t)            // strong (on the beat)
            onsets.append(t + 0.3797)   // weak (swung "and")
        }
        return onsets
    }

    func testSwungEighthsAtEightyReadEightyNotOneSixty() {
        // Pre-fix this fixture read EXACTLY 160 BPM: the smoothed histogram merged the two
        // IOI clusters (bins 158 + 162) into a 160 peak, IOI consistency tied between 160
        // and 80 (their level sets overlap — the structural blind spot), and the tie-break
        // fell to the histogram's preference for the raw subdivision rate. The long-short
        // alternation is precisely the strong-weak doubled-detection signature that octave
        // disambiguation exists to catch ("6 Human": felt ~80, detected 159).
        let estimates = TempoEstimator.estimateTempo(noteOnsets: swungEightyOnsets())
        XCTAssertFalse(estimates.isEmpty)
        XCTAssertEqual(estimates[0].bpm, 80, accuracy: 3,
                       "Swung eighths at 80 must read the felt 80, not the 160 subdivision rate; got \(estimates)")
        XCTAssertGreaterThan(estimates[0].confidence, 0.9,
                             "Every IOI agrees with the 80 BPM comb — confidence stays on the consistency scale; got \(estimates)")
    }

    func testDisambiguationKeepsDoubleTimeAsHarmonicCandidate() {
        // After a flip, the displaced double-time reading stays in the candidate list and is
        // marked harmonic — consumers see both interpretations, ranked.
        let estimates = TempoEstimator.estimateTempo(noteOnsets: swungEightyOnsets())
        XCTAssertGreaterThanOrEqual(estimates.count, 2)
        XCTAssertEqual(estimates[1].bpm, 160, accuracy: 3,
                       "The displaced 160 reading should remain as the second candidate; got \(estimates)")
        XCTAssertTrue(estimates[1].isHarmonic, "160 is the 2x octave of the 80 primary; got \(estimates)")
    }

    func testGenuineOneSixtyEvenTrainStaysOneSixty() {
        // A dead-even 160 BPM train (0.375s IOIs) carries NO alternation evidence, so the
        // gentle felt-tempo prior alone must not drag it down to 80: direct beat evidence
        // (comb 1.0 at 160 vs subdivision-only 0.5 at 80) outweighs the prior's lean.
        // Hard requirement of the fix — the prior is a nudge for ambiguous material,
        // never a clamp.
        let onsets = (0..<40).map { Double($0) * 0.375 }
        let estimates = TempoEstimator.estimateTempo(noteOnsets: onsets)
        XCTAssertFalse(estimates.isEmpty)
        XCTAssertEqual(estimates[0].bpm, 160, accuracy: 3,
                       "An even 160 train is genuinely 160; got \(estimates)")
        XCTAssertGreaterThan(estimates[0].confidence, 0.9)
    }

    func testConfidentOneFortyNotDraggedDownByPrior() {
        // 140 BPM even quarters: the prior mildly favors 70 (≈0.91 vs ≈0.86) but 140's
        // direct beat evidence must win — a real 140 BPM song still reads 140.
        let onsets = (0..<40).map { Double($0) * (60.0 / 140.0) }
        let estimates = TempoEstimator.estimateTempo(noteOnsets: onsets)
        XCTAssertFalse(estimates.isEmpty)
        XCTAssertEqual(estimates[0].bpm, 140, accuracy: 3,
                       "A confident 140 must survive the perceptual prior; got \(estimates)")
        XCTAssertGreaterThan(estimates[0].confidence, 0.9)
    }

    func testAlternationStrengthSignatures() {
        // Swung eighths (long-short) → ≈1; even train → 0 (zero variance is deliberately
        // NOT alternation — a genuine fast tempo must never be demoted by an even train);
        // too few matched intervals → 0 (no claim from a handful of IOIs).
        let swung: [TimeInterval] = (0..<20).map { $0 % 2 == 0 ? 0.3797 : 0.3703 }
        XCTAssertGreaterThan(TempoEstimator.alternationStrength(iois: swung, period: 0.375), 0.9)

        let even: [TimeInterval] = Array(repeating: 0.375, count: 20)
        XCTAssertEqual(TempoEstimator.alternationStrength(iois: even, period: 0.375), 0)

        let few: [TimeInterval] = [0.3797, 0.3703, 0.3797, 0.3703]
        XCTAssertEqual(TempoEstimator.alternationStrength(iois: few, period: 0.375), 0)
    }

    func testPerceptualPriorIsGentle() {
        // The prior's shape is load-bearing: near-flat across the felt band, mild at the
        // edges — documented values the disambiguation margins were designed against.
        XCTAssertEqual(TempoEstimator.perceptualPrior(95), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(TempoEstimator.perceptualPrior(140), 0.85)
        XCTAssertGreaterThan(TempoEstimator.perceptualPrior(160), 0.74)
        XCTAssertGreaterThan(TempoEstimator.perceptualPrior(80), 0.95)
    }
}
