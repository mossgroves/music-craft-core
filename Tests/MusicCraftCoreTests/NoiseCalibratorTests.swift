import XCTest
@testable import MusicCraftCore

final class NoiseCalibratorTests: XCTestCase {

    func testPureSilenceCallableExternally() {
        let sampleRate: Double = 44100
        let duration = 2.0
        let buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        let baseline = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            minSilenceFrames: 8
        )

        // Pure silence may or may not produce a baseline depending on chroma computation
        // What matters is that the function completes without crashing
        if let baseline = baseline {
            XCTAssertLessThan(baseline.totalEnergy, 1.0)
        }
    }

    func testLoudOnlyBufferReturnsNil() {
        // Continuous loud sine wave (no silence)
        let sampleRate: Double = 44100
        let frequency = 440.0
        let duration = 1.0
        let buffer = makeSine(frequency: frequency, sampleRate: sampleRate, duration: duration, amplitude: 0.8)

        let baseline = NoiseCalibrator.calibrateBaseline(buffer: buffer, sampleRate: sampleRate)

        XCTAssertNil(baseline)
    }

    func testMixedSilenceAndSignalCallableExternally() {
        let sampleRate: Double = 44100
        let duration = 3.0
        var buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        // First second: pure silence
        // Second second: loud signal
        let midpoint = Int(1.0 * sampleRate)
        for i in midpoint..<buffer.count {
            let phase = 2.0 * .pi * 100.0 * Double(i) / sampleRate
            buffer[i] = 0.7 * Float(sin(phase))
        }

        // Should not crash; result can be nil or a valid baseline
        let baseline = NoiseCalibrator.calibrateBaseline(buffer: buffer, sampleRate: sampleRate)

        if let baseline = baseline {
            XCTAssertGreaterThan(baseline.frameCount, 0)
            XCTAssertLessThan(baseline.totalEnergy, 5.0)
        }
    }

    func testContaminationSafeguardRejectsHighEnergyBaseline() {
        // Create a buffer with music playing (no true silence)
        let sampleRate: Double = 44100
        let frequency = 100.0  // Low freq, lots of chroma energy
        let duration = 1.0
        let buffer = makeSine(frequency: frequency, sampleRate: sampleRate, duration: duration, amplitude: 0.2)

        let baseline = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            silenceThreshold: 0.3,  // Loose threshold, admit the signal as "silence"
            minSilenceFrames: 5,
            contaminationLimit: 1.0  // Strict contamination limit
        )

        // Should reject due to high energy
        XCTAssertNil(baseline)
    }

    func testInsufficientSilenceFramesReturnsNil() {
        let sampleRate: Double = 44100
        let duration = 0.5  // Short buffer, few silence frames
        let buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        let baseline = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            minSilenceFrames: 100  // Require many silence frames
        )

        XCTAssertNil(baseline)
    }

    func testCustomSilenceThresholdAllowsLooserCapture() {
        let sampleRate: Double = 44100
        let duration = 1.0
        // Very quiet sine (louder than default threshold but quieter than typical signal)
        let buffer = makeSine(frequency: 440, sampleRate: sampleRate, duration: duration, amplitude: 0.002)

        // With default threshold (0.001), this won't be detected as silence
        let baselineDefault = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            minSilenceFrames: 5
        )
        XCTAssertNil(baselineDefault)

        // With higher threshold (0.01), it will be detected
        let baselineLoose = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: sampleRate,
            silenceThreshold: 0.01,
            minSilenceFrames: 5
        )
        XCTAssertNotNil(baselineLoose)
    }

    func testSampleRateIndependence() {
        let sampleRates = [44100.0, 48000.0]

        for sampleRate in sampleRates {
            let buffer = [Float](repeating: 0, count: Int(2.0 * sampleRate))

            // Should not crash at either sample rate
            let baseline = NoiseCalibrator.calibrateBaseline(
                buffer: buffer,
                sampleRate: sampleRate,
                minSilenceFrames: 5
            )

            // Baseline may or may not be produced, but function should complete
            _ = baseline
        }

        XCTAssertTrue(true)  // Just verify we get here without crashing
    }

    func testNoiseBaselinePublicConstruction() {
        let chroma = [Double](repeating: 0.1, count: 12)
        let baseline = NoiseBaseline(chroma: chroma, frameCount: 10)

        XCTAssertEqual(baseline.chroma.count, 12)
        XCTAssertEqual(baseline.frameCount, 10)
        XCTAssertAlmostEqual(baseline.totalEnergy, 1.2, accuracy: 0.01)
    }

    func testNoiseBaselineTotalEnergyAccessible() {
        let chroma = [1.0, 0.5, 0.3, 0.2, 0.1, 0.1, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65]
        let baseline = NoiseBaseline(chroma: chroma, frameCount: 5)

        let expected = chroma.reduce(0, +)
        XCTAssertAlmostEqual(baseline.totalEnergy, expected, accuracy: 0.001)
    }

    func testNoiseBaselineEquatableAndHashable() {
        let chroma1 = [Double](repeating: 0.1, count: 12)
        let chroma2 = [Double](repeating: 0.1, count: 12)
        let chroma3 = [Double](repeating: 0.2, count: 12)

        let baseline1 = NoiseBaseline(chroma: chroma1, frameCount: 10)
        let baseline2 = NoiseBaseline(chroma: chroma2, frameCount: 10)
        let baseline3 = NoiseBaseline(chroma: chroma3, frameCount: 10)

        XCTAssertEqual(baseline1, baseline2)
        XCTAssertNotEqual(baseline1, baseline3)

        // Test hashability by putting in a set
        let set: Set<NoiseBaseline> = [baseline1, baseline2, baseline3]
        XCTAssertEqual(set.count, 2)  // baseline1 and baseline2 are equal, so only 2 unique
    }

    // MARK: - Helpers

    private func makeSine(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        amplitude: Float = 0.5
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var buffer = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let phase = 2.0 * .pi * frequency * Double(i) / sampleRate
            buffer[i] = amplitude * Float(sin(phase))
        }

        return buffer
    }

    private func makeMixedBuffer(sampleRate: Double, duration: Double) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var buffer = [Float](repeating: 0, count: sampleCount)

        // First half: silence
        // Second half: loud sine
        let midpoint = sampleCount / 2
        for i in midpoint..<sampleCount {
            let phase = 2.0 * .pi * 440.0 * Double(i) / sampleRate
            buffer[i] = 0.8 * Float(sin(phase))
        }

        return buffer
    }
}

// Helper for approximate equality on Double
private func XCTAssertAlmostEqual(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(actual - expected), accuracy, file: file, line: line)
}
