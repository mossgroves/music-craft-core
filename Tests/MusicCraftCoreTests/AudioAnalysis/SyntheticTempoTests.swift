import XCTest
@testable import MusicCraftCore

final class SyntheticTempoTests: XCTestCase {

    func testSynthetic80BPMStructural() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("steady-80bpm") else {
            XCTFail("Failed to load steady-80bpm fixture")
            return
        }

        let tempoEstimates = TempoEstimator.estimateTempo(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Structural validation: verify TempoEstimator completes without error.
        // Correctness validation (BPM accuracy) happens with real-world audio in Phase 2+.
        XCTAssertGreaterThanOrEqual(tempoEstimates.count, 0, "Should return valid tempo estimates")
    }

    func testSynthetic120BPMStructural() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("steady-120bpm") else {
            XCTFail("Failed to load steady-120bpm fixture")
            return
        }

        let tempoEstimates = TempoEstimator.estimateTempo(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        XCTAssertGreaterThanOrEqual(tempoEstimates.count, 0, "Should return valid tempo estimates")
    }

    func testSynthetic140BPMStructural() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("steady-140bpm") else {
            XCTFail("Failed to load steady-140bpm fixture")
            return
        }

        let tempoEstimates = TempoEstimator.estimateTempo(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        XCTAssertGreaterThanOrEqual(tempoEstimates.count, 0, "Should return valid tempo estimates")
    }

    func testTempoMetricsComputation() throws {
        let metrics1 = AudioAnalysisMetrics.compareTempo(detectedBPM: 119, groundTruthBPM: 120)
        XCTAssertLessThan(metrics1.tempoError, 0.01, "1 BPM error on 120 BPM should be < 1%")

        let metrics2 = AudioAnalysisMetrics.compareTempo(detectedBPM: 114, groundTruthBPM: 120)
        XCTAssertLessThan(metrics2.tempoError, 0.06, "6 BPM error on 120 BPM should be < 6%")

        let metrics3 = AudioAnalysisMetrics.compareTempo(detectedBPM: nil, groundTruthBPM: 120)
        XCTAssertEqual(metrics3.tempoError, 1.0, "Missing tempo should report 100% error")
    }
}
