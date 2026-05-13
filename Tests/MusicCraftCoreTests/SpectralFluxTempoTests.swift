import XCTest
@testable import MusicCraftCore

/// Regression tests for the 0.0.11 spectral-flux tempo estimator.
///
/// Anchors:
/// - synthetic 120 BPM click track: hard gate against the pre-0.0.11 1/3-tempo bug.
/// - synthetic silence / single-onset cases: empty-output safety.
/// - SpectralFluxOnsetDetector low-level coverage: empty buffer, threshold sensitivity.
final class SpectralFluxTempoTests: XCTestCase {

    // MARK: - SpectralFluxOnsetDetector

    func testOnsetDetectorEmptyBuffer() {
        let onsets = SpectralFluxOnsetDetector.detectOnsets(buffer: [], sampleRate: 44100)
        XCTAssertEqual(onsets.count, 0)
    }

    func testOnsetDetectorSilence() {
        let buffer = [Float](repeating: 0, count: 44100)
        let onsets = SpectralFluxOnsetDetector.detectOnsets(buffer: buffer, sampleRate: 44100)
        XCTAssertEqual(onsets.count, 0, "Silence must produce no onsets.")
    }

    func testOnsetDetectorClickTrackProducesOnsets() {
        // 5 evenly-spaced 50ms clicks at 1kHz, embedded in silence at 44100Hz mono.
        let sampleRate: Double = 44100
        let totalDurationSec: Double = 5.0
        let clickIntervalSec: Double = 0.5
        let clickDurationSec: Double = 0.05
        let clickFreq: Double = 1000

        var buffer = [Float](repeating: 0, count: Int(totalDurationSec * sampleRate))
        var clickStart: Double = 0
        while clickStart < totalDurationSec {
            let startSample = Int(clickStart * sampleRate)
            let clickSamples = Int(clickDurationSec * sampleRate)
            for i in 0..<clickSamples where startSample + i < buffer.count {
                let t = Double(i) / sampleRate
                buffer[startSample + i] = Float(0.8 * sin(2.0 * .pi * clickFreq * t))
            }
            clickStart += clickIntervalSec
        }

        let onsets = SpectralFluxOnsetDetector.detectOnsets(
            buffer: buffer,
            sampleRate: sampleRate
        )

        XCTAssertGreaterThanOrEqual(onsets.count, 5, "5 clicks should yield at least 5 onsets, got \(onsets.count).")

        // Onsets should be monotonically increasing.
        for i in 1..<onsets.count {
            XCTAssertGreaterThan(onsets[i], onsets[i - 1])
        }
    }

    // MARK: - TempoHistogram

    func testTempoHistogramTooFewOnsets() {
        XCTAssertEqual(TempoHistogram.estimate(onsets: []).count, 0)
        XCTAssertEqual(TempoHistogram.estimate(onsets: [1.0]).count, 0)
    }

    func testTempoHistogramRegularBeatsProducesMatchingBpm() {
        // 8 onsets at 0.5s intervals = 120 BPM.
        let onsets: [TimeInterval] = (0..<8).map { Double($0) * 0.5 }
        let peaks = TempoHistogram.estimate(onsets: onsets)

        XCTAssertFalse(peaks.isEmpty, "Regular onsets must yield at least one peak.")
        guard let primary = peaks.first else { return }

        // 120 BPM ± 5% = 114–126 BPM. Histogram is 1-BPM-resolution, so we expect 120 or
        // an immediate neighbor smoothed in (118–122).
        XCTAssertEqual(primary.bpm, 120, accuracy: 5, "Primary BPM must be near 120, got \(primary.bpm).")
    }

    // MARK: - TempoEstimator buffer path (regression for the 1/3-bug)

    func testEstimateTempoFromBufferOn120BpmClickTrack() {
        // The canonical regression fixture from 0.0.11 spec: 10s of 120 BPM clicks.
        // Pre-0.0.11 the algorithm returned ~40 BPM (1/3 of 120) on similar fixtures.
        let sampleRate: Double = 44100
        let totalDurationSec: Double = 10.0
        let clickIntervalSec: Double = 0.5 // 120 BPM
        let clickDurationSec: Double = 0.05
        let clickFreq: Double = 1000

        var buffer = [Float](repeating: 0, count: Int(totalDurationSec * sampleRate))
        var clickStart: Double = 0
        while clickStart < totalDurationSec {
            let startSample = Int(clickStart * sampleRate)
            let clickSamples = Int(clickDurationSec * sampleRate)
            for i in 0..<clickSamples where startSample + i < buffer.count {
                let t = Double(i) / sampleRate
                buffer[startSample + i] = Float(0.8 * sin(2.0 * .pi * clickFreq * t))
            }
            clickStart += clickIntervalSec
        }

        let tempos = TempoEstimator.estimateTempo(buffer: buffer, sampleRate: sampleRate)

        XCTAssertFalse(tempos.isEmpty, "10s of 120 BPM clicks must produce at least one tempo estimate.")
        guard let primary = tempos.first else { return }

        // ±5% of 120 = 114–126. Anything else (and especially anything near 40 = the prior bug)
        // is a regression.
        XCTAssertEqual(
            primary.bpm,
            120,
            accuracy: 6,
            "Primary BPM must be near 120, got \(primary.bpm) — regression for the pre-0.0.11 1/3-tempo bug."
        )
    }

    func testEstimateTempoFromBufferOnSilenceReturnsEmpty() {
        let buffer = [Float](repeating: 0, count: 44100 * 5)
        let tempos = TempoEstimator.estimateTempo(buffer: buffer, sampleRate: 44100)
        XCTAssertEqual(tempos.count, 0, "Silence must produce no tempo estimates.")
    }

    func testEstimateTempoFromBufferOnLowRhythmContentHasLowConfidence() {
        // Continuous 440Hz tone (sustained, no onsets after the very first frame).
        // This stands in for the voice-fixture confidence assertion in the spec — TTS speech
        // would also produce low confidence, but the synthetic case is portable and
        // sampleRate-independent.
        let sampleRate: Double = 44100
        let durationSec: Double = 5.0
        var buffer = [Float](repeating: 0, count: Int(durationSec * sampleRate))
        for i in 0..<buffer.count {
            let t = Double(i) / sampleRate
            buffer[i] = Float(0.3 * sin(2.0 * .pi * 440.0 * t))
        }

        let tempos = TempoEstimator.estimateTempo(buffer: buffer, sampleRate: sampleRate)

        if let primary = tempos.first {
            XCTAssertLessThan(
                primary.confidence,
                0.5,
                "Sustained tone with no onsets should produce low-confidence estimate (got \(primary.confidence) at \(primary.bpm) BPM)."
            )
        }
        // Empty array is also acceptable — no histogram evidence means no estimate, which
        // is what the Sanctuary display gate (confidence ≥ 0.3) wants anyway.
    }
}
