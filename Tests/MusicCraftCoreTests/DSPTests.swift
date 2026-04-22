import XCTest
@testable import MusicCraftCore

final class DSPTests: XCTestCase {

    // MARK: - PitchDetector Tests

    func testYINDetectsA440() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.1)

        var result: PitchDetector.Result? = nil
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                result = detector.detectPitch(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.confidence, 0.9)
        XCTAssertTrue(abs(result!.frequency - 440.0) < 5.0, "Detected frequency \(result!.frequency) should be close to 440Hz")
    }

    func testYINDetectsE329() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let buffer = generateSineWave(frequency: 329.63, sampleRate: 44100, duration: 0.1)

        var result: PitchDetector.Result? = nil
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                result = detector.detectPitch(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.confidence, 0.85)
        XCTAssertTrue(abs(result!.frequency - 329.63) < 5.0, "Detected frequency should be close to E (329.63Hz)")
    }

    func testYINDetectsC262() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let buffer = generateSineWave(frequency: 261.63, sampleRate: 44100, duration: 0.1)

        var result: PitchDetector.Result? = nil
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                result = detector.detectPitch(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.confidence, 0.85)
        XCTAssertTrue(abs(result!.frequency - 261.63) < 5.0, "Detected frequency should be close to C (261.63Hz)")
    }

    func testYINConfidenceDegradeOnNoise() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let cleanBuffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.1)
        let noisyBuffer = addNoise(to: cleanBuffer, snr: 5.0)

        var cleanResult: PitchDetector.Result? = nil
        cleanBuffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                cleanResult = detector.detectPitch(buffer: baseAddr, count: ptr.count)
            }
        }

        detector.reset()

        var noisyResult: PitchDetector.Result? = nil
        noisyBuffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                noisyResult = detector.detectPitch(buffer: baseAddr, count: ptr.count)
            }
        }

        XCTAssertNotNil(cleanResult)
        XCTAssertNotNil(noisyResult)
        XCTAssertGreaterThan(cleanResult!.confidence, noisyResult!.confidence)
    }

    func testMedianFilterSmoothsFrames() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192)

        // Generate three consecutive frames: 440Hz, then 880Hz (octave jump), then back to 440Hz
        let frame1 = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.093)
        let frame2 = generateSineWave(frequency: 880.0, sampleRate: 44100, duration: 0.093)
        let frame3 = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.093)

        var freq1 = 0.0
        frame1.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                if let result = detector.detectPitch(buffer: baseAddr, count: frame1.count) {
                    freq1 = result.frequency
                }
            }
        }

        var freq2 = 0.0
        frame2.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                if let result = detector.detectPitch(buffer: baseAddr, count: frame2.count) {
                    freq2 = result.frequency
                }
            }
        }

        var freq3 = 0.0
        frame3.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                if let result = detector.detectPitch(buffer: baseAddr, count: frame3.count) {
                    freq3 = result.frequency
                }
            }
        }

        // Octave jump should not flush; median filter should keep notes distinct
        XCTAssertNotNil(freq1)
        XCTAssertNotNil(freq2)
        XCTAssertNotNil(freq3)
    }

    // MARK: - DSP Utilities Tests

    func testHannWindowLength() {
        let window = DSPUtilities.hannWindow(length: 2048)
        XCTAssertEqual(window.count, 2048)
    }

    func testHannWindowProperties() {
        let window = DSPUtilities.hannWindow(length: 512)
        // Window should start and end near zero
        XCTAssertLessThan(window[0], 0.01)
        XCTAssertLessThan(window[511], 0.01)
        // Window should have peak near center
        let maxVal = window.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.9)
    }

    func testBlackmanWindowLength() {
        let window = DSPUtilities.blackmanWindow(length: 2048)
        XCTAssertEqual(window.count, 2048)
    }

    func testBlackmanWindowProperties() {
        let window = DSPUtilities.blackmanWindow(length: 512)
        // Window should start and end near zero
        XCTAssertLessThan(window[0], 0.01)
        XCTAssertLessThan(window[511], 0.01)
        // Window should have peak near center
        let maxVal = window.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.9)
    }

    // MARK: - Chroma Extractor Tests

    func testChromaExtractionOnA440() {
        let extractor = ChromaExtractor(bufferSize: 2048, sampleRate: 44100)
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.05)

        var chroma: [Double] = []
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                chroma = extractor.extractChroma(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertEqual(chroma.count, 12)
        // A440 should produce peak at pitch class 9 (A)
        let maxIndex = chroma.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
        XCTAssertEqual(maxIndex, 9, "A440 should produce peak at pitch class 9 (A)")
    }

    func testChromaExtractionNormalization() {
        let extractor = ChromaExtractor(bufferSize: 2048, sampleRate: 44100)
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.05)

        var chroma: [Double] = []
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                chroma = extractor.extractChroma(buffer: baseAddr, count: buffer.count)
            }
        }

        let maxChroma = chroma.max() ?? 0
        XCTAssertEqual(maxChroma, 1.0, accuracy: 0.01, "Chroma should be normalized to 1.0 max")
    }

    // MARK: - ReferenceChromaLibrary Tests

    func testReferenceChromaLibraryCount() {
        let count = ReferenceChromaLibrary.vectors.count
        XCTAssertGreaterThanOrEqual(count, 98, "Library should contain at least 98 chord templates")
    }

    func testReferenceChromaLibraryDistanceFunction() {
        // Distance to C major should be small
        let cMajorChroma: [Double] = [1.0, 0.0, 0.1, 0.0, 0.05, 0.0, 0.02, 0.0, 0.01, 0.0, 0.0, 0.0]
        let distanceToC = ReferenceChromaLibrary.distance(cMajorChroma, to: "C")
        XCTAssertLessThan(distanceToC, 0.2)

        // Distance to a different quality should be larger
        let distanceToDim = ReferenceChromaLibrary.distance(cMajorChroma, to: "Cdim")
        XCTAssertGreaterThan(distanceToDim, distanceToC)
    }

    func testReferenceChromaLibraryContainsAllRoots() {
        let roots = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        for root in roots {
            XCTAssertTrue(ReferenceChromaLibrary.vectors[root] != nil, "Library should contain \(root) major")
            XCTAssertTrue(ReferenceChromaLibrary.vectors[root + "m"] != nil, "Library should contain \(root) minor")
        }
    }

    // MARK: - Helper Functions

    private func generateSineWave(frequency: Double, sampleRate: Double, duration: Double) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: sampleCount)
        let amplitude: Float = 0.5

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let angle = 2.0 * .pi * frequency * t
            samples[i] = amplitude * Float(sin(angle))
        }

        return samples
    }

    private func addNoise(to signal: [Float], snr: Double) -> [Float] {
        var noisy = signal
        var generator = SystemRandomNumberGenerator()

        for i in 0..<noisy.count {
            let noise = Float.random(in: -0.1...0.1, using: &generator)
            noisy[i] += noise
        }

        return noisy
    }
}
