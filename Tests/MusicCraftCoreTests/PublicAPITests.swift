import XCTest
import MusicCraftCore

/// Tests that exercise the public DSP API surface without @testable import.
/// These tests verify that DSP types are correctly exposed as public and can be consumed from external packages.
final class PublicAPITests: XCTestCase {

    // MARK: - PitchDetector Public API

    func testPitchDetectorPublicInit() {
        // Should be able to construct via public init
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        XCTAssertNotNil(detector)
    }

    func testPitchDetectorPublicDetectPitch() {
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.1)

        var result: PitchDetector.Result? = nil
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                result = detector.detectPitch(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.confidence, 0.85)
        XCTAssertTrue(abs(result!.frequency - 440.0) < 5.0)
    }

    func testPitchDetectorResult() {
        // Verify Result struct is public and accessible
        let detector = PitchDetector(sampleRate: 44100, bufferSize: 8192, threshold: 0.15)
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.1)

        var result: PitchDetector.Result? = nil
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                result = detector.detectPitch(buffer: baseAddr, count: buffer.count)
            }
        }

        if let r = result {
            XCTAssertGreaterThanOrEqual(r.confidence, 0.0)
            XCTAssertLessThanOrEqual(r.confidence, 1.0)
            XCTAssertGreaterThan(r.frequency, 0.0)
        }
    }

    // MARK: - ChromaExtractor Public API

    func testChromaExtractorPublicInit() {
        let extractor = ChromaExtractor(bufferSize: 8192, sampleRate: 44100)
        XCTAssertNotNil(extractor)
    }

    func testChromaExtractorExtractChroma() {
        let extractor = ChromaExtractor(bufferSize: 8192, sampleRate: 44100)
        let buffer = generateCMajorChord(sampleRate: 44100, duration: 0.1)

        var chroma: [Double] = []
        buffer.withUnsafeBytes { ptr in
            if let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: Float.self) {
                chroma = extractor.extractChroma(buffer: baseAddr, count: buffer.count)
            }
        }

        XCTAssertEqual(chroma.count, 12)
        // C, E, G should be among the top 3 bins
        let sortedIndices = (0..<12).sorted { chroma[$0] > chroma[$1] }
        let topThree = Set(sortedIndices.prefix(3))
        let expected = Set([0, 4, 7])  // C, E, G
        XCTAssertTrue(expected.isSubset(of: topThree))
    }

    // MARK: - CanonicalChromaLibrary Public API

    func testCanonicalChromaLibraryPublicInit() {
        let library = CanonicalChromaLibrary()
        XCTAssertNotNil(library)
    }

    func testCanonicalChromaLibraryDistance() {
        let library = CanonicalChromaLibrary()
        let cMajorChroma: [Double] = [1.0, 0.0, 0.1, 0.0, 0.05, 0.0, 0.02, 0.0, 0.01, 0.0, 0.0, 0.0]
        let distance = library.distance(cMajorChroma, to: "C")
        XCTAssertTrue(distance.isFinite)
        XCTAssertLessThan(distance, 0.5)
    }

    func testCanonicalChromaLibraryAvailableChordNames() {
        let library = CanonicalChromaLibrary()
        let names = library.availableChordNames
        XCTAssertGreaterThanOrEqual(names.count, 120)
        XCTAssertTrue(names.contains("C"))
        XCTAssertTrue(names.contains("Am"))
        XCTAssertTrue(names.contains("G7"))
    }

    func testChromaTemplateLibraryProtocol() {
        // Verify that CanonicalChromaLibrary conforms to the protocol
        let library: ChromaTemplateLibrary = CanonicalChromaLibrary()
        let names = library.availableChordNames
        let distance = library.distance([1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], to: "C")
        XCTAssertGreaterThan(names.count, 0)
        XCTAssertTrue(distance.isFinite)
    }

    // MARK: - DSPUtilities Public API

    func testDSPUtilitiesHannWindow() {
        let window = DSPUtilities.hannWindow(length: 8192)
        XCTAssertEqual(window.count, 8192)
        // Edges should taper to near 0
        XCTAssertLessThan(abs(Double(window[0])), 0.001)
        XCTAssertLessThan(abs(Double(window[8191])), 0.001)
    }

    func testDSPUtilitiesBlackmanWindow() {
        let window = DSPUtilities.blackmanWindow(length: 8192)
        XCTAssertEqual(window.count, 8192)
        // Edges should taper to near 0
        XCTAssertLessThan(abs(Double(window[0])), 0.001)
        XCTAssertLessThan(abs(Double(window[8191])), 0.001)
    }

    func testDSPUtilitiesLog2Ceil() {
        XCTAssertEqual(DSPUtilities.log2Ceil(1024), 10)
        XCTAssertEqual(DSPUtilities.log2Ceil(2048), 11)
        XCTAssertEqual(DSPUtilities.log2Ceil(2049), 12)
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

    private func generateCMajorChord(sampleRate: Double, duration: Double) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: sampleCount)
        let frequencies = [261.63, 329.63, 392.0]  // C, E, G
        let amplitude: Float = 0.15

        for freq in frequencies {
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let angle = 2.0 * .pi * freq * t
                samples[i] += amplitude * Float(sin(angle))
            }
        }

        return samples
    }
}
