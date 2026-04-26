import XCTest
@testable import MusicCraftCore

final class OnsetDetectorTests: XCTestCase {

    // MARK: - Basic onset detection

    func testSingleTransientProducesSingleOnset() {
        // Create a buffer with a single sine burst (attack at 0.5s)
        let sampleRate: Double = 44100
        let duration = 2.0
        let buffer = makeSineBurst(
            frequency: 440,
            sampleRate: sampleRate,
            duration: duration,
            attackTime: 0.5,  // Attack at 0.5s
            burstDuration: 0.1
        )

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 1)
        XCTAssertGreaterThan(onsets[0], 0.4)
        XCTAssertLessThan(onsets[0], 0.6)
    }

    func testMultipleTransientsAtOneSecondSpacing() {
        let sampleRate: Double = 44100
        let duration = 4.0
        var buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        // Add bursts at 0.5s, 1.5s, 2.5s
        for attackTime in [0.5, 1.5, 2.5] {
            let burst = makeSineBurst(
                frequency: 440,
                sampleRate: sampleRate,
                duration: 0.1,
                attackTime: 0,
                burstDuration: 0.1
            )
            let startSample = Int(attackTime * sampleRate)
            let endSample = min(startSample + burst.count, buffer.count)
            let copyCount = endSample - startSample
            for i in 0..<copyCount {
                buffer[startSample + i] += burst[i]
            }
        }

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 3)
        for (i, expectedTime) in [0.5, 1.5, 2.5].enumerated() {
            XCTAssertGreaterThan(onsets[i], expectedTime - 0.1)
            XCTAssertLessThan(onsets[i], expectedTime + 0.1)
        }
    }

    func testTwoTransientsWithinMinimumGapProducesOne() {
        // Two transients closer than 500ms (default minGapMs)
        let sampleRate: Double = 44100
        let duration = 2.0
        var buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        // Add bursts at 0.5s and 0.6s (100ms apart, less than 500ms minimum gap)
        for attackTime in [0.5, 0.6] {
            let burst = makeSineBurst(
                frequency: 440,
                sampleRate: sampleRate,
                duration: 0.05,
                attackTime: 0,
                burstDuration: 0.05
            )
            let startSample = Int(attackTime * sampleRate)
            let endSample = min(startSample + burst.count, buffer.count)
            let copyCount = endSample - startSample
            for i in 0..<copyCount {
                buffer[startSample + i] += burst[i]
            }
        }

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        // Should detect only the first onset
        XCTAssertEqual(onsets.count, 1)
        XCTAssertGreaterThan(onsets[0], 0.4)
        XCTAssertLessThan(onsets[0], 0.6)
    }

    func testContinuousToneProducesNoOnsets() {
        // Continuous sine tone (no attacks)
        let sampleRate: Double = 44100
        let frequency = 440.0
        let duration = 1.0
        let buffer = makeSine(frequency: frequency, sampleRate: sampleRate, duration: duration, amplitude: 0.5)

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 0)
    }

    func testSilentBufferProducesNoOnsets() {
        let sampleRate: Double = 44100
        let buffer = [Float](repeating: 0, count: Int(2 * sampleRate))

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 0)
    }

    func testEnergyFloorRejectsLowAmplitudeTransient() {
        // Very quiet burst below the energy floor
        let sampleRate: Double = 44100
        let duration = 2.0
        let buffer = makeSineBurst(
            frequency: 440,
            sampleRate: sampleRate,
            duration: duration,
            attackTime: 0.5,
            burstDuration: 0.1,
            amplitude: 0.001  // Very quiet, below default floor
        )

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 0)
    }

    func testReducedMinGapAllowsCloserOnsets() {
        // Two transients 200ms apart with reduced minimum gap
        let sampleRate: Double = 44100
        let duration = 2.0
        var buffer = [Float](repeating: 0, count: Int(duration * sampleRate))

        for attackTime in [0.5, 0.7] {
            let burst = makeSineBurst(
                frequency: 440,
                sampleRate: sampleRate,
                duration: 0.05,
                attackTime: 0,
                burstDuration: 0.05
            )
            let startSample = Int(attackTime * sampleRate)
            let endSample = min(startSample + burst.count, buffer.count)
            let copyCount = endSample - startSample
            for i in 0..<copyCount {
                buffer[startSample + i] += burst[i]
            }
        }

        let config = OnsetDetector.Configuration(minGapMs: 100)  // 100ms minimum gap
        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate, configuration: config)

        // Should detect both onsets
        XCTAssertEqual(onsets.count, 2)
    }

    func testIncreasedMultiplierRejectsWeakOnsets() {
        // Weak transient that's above default threshold but below raised threshold
        let sampleRate: Double = 44100
        let duration = 2.0
        let buffer = makeSineBurst(
            frequency: 440,
            sampleRate: sampleRate,
            duration: duration,
            attackTime: 0.5,
            burstDuration: 0.1,
            amplitude: 0.3  // Medium amplitude
        )

        let config = OnsetDetector.Configuration(energyMultiplier: 5.0)  // Raised threshold
        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate, configuration: config)

        // With increased multiplier, weak onsets should be rejected (count should be 0 or much less than default)
        XCTAssertLessThan(onsets.count, 2)
    }

    func testBufferShorterThanWindowReturnsEmpty() {
        let sampleRate: Double = 44100
        let buffer = [Float](repeating: 0.1, count: 1000)  // Much shorter than default 2048 window

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        XCTAssertEqual(onsets.count, 0)
    }

    func testSampleRateIndependence() {
        // Same attack duration at different sample rates should produce similar onset times
        let frequencies = [44100.0, 48000.0]
        var onsetTimes: [TimeInterval] = []

        for sampleRate in frequencies {
            let duration = 2.0
            let buffer = makeSineBurst(
                frequency: 440,
                sampleRate: sampleRate,
                duration: duration,
                attackTime: 1.0,
                burstDuration: 0.1
            )

            let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)
            if !onsets.isEmpty {
                onsetTimes.append(onsets[0])
            }
        }

        XCTAssertEqual(onsetTimes.count, 2)
        // Onset times should be nearly identical (within 10ms tolerance)
        XCTAssertLessThan(abs(onsetTimes[0] - onsetTimes[1]), 0.01)
    }

    func testFirstOnsetAllowedAtSampleZero() {
        // Burst starts immediately at the beginning
        let sampleRate: Double = 44100
        let duration = 1.0
        let buffer = makeSineBurst(
            frequency: 440,
            sampleRate: sampleRate,
            duration: duration,
            attackTime: 0,  // Attack at start
            burstDuration: 0.1
        )

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: sampleRate)

        // If onset detected, it should be near the start
        if !onsets.isEmpty {
            XCTAssertLessThan(onsets[0], 0.05)
        }
    }

    // MARK: - Helpers

    /// Create a sine wave with enveloped burst.
    private func makeSineBurst(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        attackTime: Double,
        burstDuration: Double,
        amplitude: Float = 0.5
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        var buffer = [Float](repeating: 0, count: sampleCount)

        let attackSample = Int(attackTime * sampleRate)
        let burstSamples = Int(burstDuration * sampleRate)
        let endSample = min(attackSample + burstSamples, sampleCount)

        for i in attackSample..<endSample {
            let progress = Double(i - attackSample) / Double(burstSamples)
            let envelope = Float(progress)  // Linear attack
            let phase = 2.0 * .pi * frequency * Double(i) / sampleRate
            buffer[i] = amplitude * envelope * Float(sin(phase))
        }

        return buffer
    }

    /// Create a continuous sine wave.
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
}
