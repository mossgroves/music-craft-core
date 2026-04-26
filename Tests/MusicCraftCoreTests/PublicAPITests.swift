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

    // MARK: - ChordDetector Public API

    func testChordDetectorPublicInit() {
        let library = CanonicalChromaLibrary()
        // Should be able to construct via public init with required template library
        let detector = ChordDetector(chromaTemplateLibrary: library)
        XCTAssertNotNil(detector)
    }

    func testChordDetectorPublicInitWithClassifier() {
        let library = CanonicalChromaLibrary()
        let stub = StubClassifierProvider()
        // Should support optional classifier provider
        let detector = ChordDetector(chromaTemplateLibrary: library, classifierProvider: stub)
        XCTAssertNotNil(detector)
    }

    func testChordDetectorDetectChordFromChroma() {
        let library = CanonicalChromaLibrary()
        let detector = ChordDetector(chromaTemplateLibrary: library)

        // C major chroma: strong C, E, G
        let cMajorChroma: [Double] = [1.0, 0.0, 0.1, 0.0, 0.8, 0.0, 0.05, 0.6, 0.0, 0.0, 0.0, 0.0]
        let result = detector.detectChord(chroma: cMajorChroma)

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.chord)
        XCTAssertGreaterThan(result?.chord.confidence ?? 0, 0.0)
    }

    func testChordDetectorReset() {
        let library = CanonicalChromaLibrary()
        let detector = ChordDetector(chromaTemplateLibrary: library)

        // After reset, should not have processed chroma
        detector.reset()
        XCTAssertNil(detector.lastProcessedChroma)
        XCTAssertFalse(detector.isNoiseBaselineCalibrated)
    }

    func testChordDetectorTuningKnobsAsParameters() {
        let library = CanonicalChromaLibrary()
        // Should be able to pass custom tuning parameters
        let detector = ChordDetector(
            chromaTemplateLibrary: library,
            silenceCalibrationThreshold: 6.0,
            subtractFloor: 0.15,
            energyGateMultiplier: 0.6,
            confidenceFallbackThreshold: 0.50,
            agreementBoostFull: 0.12,
            agreementBoostRootOnly: 0.06
        )
        XCTAssertNotNil(detector)
    }

    // MARK: - IntervalDetector Public API

    func testIntervalDetectorDetectChord() {
        // C major: C, E, G
        let cMajorChroma: [Double] = [1.0, 0.0, 0.1, 0.0, 0.8, 0.0, 0.0, 0.6, 0.0, 0.0, 0.0, 0.0]
        let result = IntervalDetector.detect(chroma: cMajorChroma)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.root, NoteName.C)
        XCTAssertEqual(result?.quality, ChordQuality.major)
        XCTAssertGreaterThan(result?.confidence ?? 0, 0.0)
    }

    func testIntervalDetectorMinorChord() {
        // A minor: A (9), C (0), E (4)
        // Using significant energy at these bins
        var aMinorChroma = [Double](repeating: 0, count: 12)
        aMinorChroma[9] = 1.0   // A
        aMinorChroma[0] = 0.7   // C
        aMinorChroma[4] = 0.8   // E

        let result = IntervalDetector.detect(chroma: aMinorChroma)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.root, NoteName.A)
        XCTAssertEqual(result?.quality, ChordQuality.minor)
    }

    func testIntervalDetectorPowerChord() {
        // G5: G (7) and D (2) with enough energy to trigger power chord path
        // Also add minor 3rd (Bb at 10) to help with chord completion
        var g5Chroma = [Double](repeating: 0, count: 12)
        g5Chroma[7] = 1.0    // G
        g5Chroma[2] = 0.9    // D
        g5Chroma[10] = 0.12  // Bb for minor 3rd above threshold

        let result = IntervalDetector.detect(chroma: g5Chroma)

        XCTAssertNotNil(result)
        if let r = result {
            XCTAssertEqual(r.root, NoteName.G)
        }
    }

    func testIntervalDetectorWithRawChromaMinorProtection() {
        // Test minor 3rd protection with raw chroma parameter
        let processedChroma: [Double] = [1.0, 0.0, 0.0, 0.0, 0.8, 0.0, 0.0, 0.6, 0.0, 0.0, 0.0, 0.0]
        let rawChroma: [Double] = [1.0, 0.0, 0.3, 0.0, 0.7, 0.0, 0.0, 0.6, 0.0, 0.0, 0.0, 0.0]

        let result = IntervalDetector.detect(chroma: processedChroma, rawChroma: rawChroma)
        XCTAssertNotNil(result)
    }

    // MARK: - ChordDetector.Result Public Initializer

    func testChordDetectorResultPublicInit() {
        // Verify that Result can be constructed from external module via public init
        let chord = Chord(root: .C, quality: .major)
        let chroma = [1.0, 0.0, 0.1, 0.0, 0.8, 0.0, 0.05, 0.6, 0.0, 0.0, 0.0, 0.0]

        // This should compile and run without errors
        let result = ChordDetector.Result(chord: chord, chroma: chroma)

        XCTAssertEqual(result.chord.root, .C)
        XCTAssertEqual(result.chord.quality, .major)
        XCTAssertEqual(result.chroma.count, 12)
        XCTAssertEqual(result.chroma[0], 1.0)
    }

    // MARK: - IntervalDetector.Result and Peak Public Initializers

    func testIntervalDetectorPeakPublicInit() {
        // Verify that Peak can be constructed from external module via public init
        let peak = IntervalDetector.Peak(note: .C, energy: 0.95)

        XCTAssertEqual(peak.note, .C)
        XCTAssertEqual(peak.energy, 0.95)
    }

    func testIntervalDetectorResultPublicInit() {
        // Verify that Result can be constructed from external module via public init
        let peak1 = IntervalDetector.Peak(note: .C, energy: 1.0)
        let peak2 = IntervalDetector.Peak(note: .E, energy: 0.8)
        let peak3 = IntervalDetector.Peak(note: .G, energy: 0.6)
        let peaks = [peak1, peak2, peak3]

        // This should compile and run without errors
        let result = IntervalDetector.Result(
            root: .C,
            quality: .major,
            confidence: 0.90,
            peaks: peaks
        )

        XCTAssertEqual(result.root, .C)
        XCTAssertEqual(result.quality, .major)
        XCTAssertEqual(result.confidence, 0.90)
        XCTAssertEqual(result.peaks.count, 3)
        XCTAssertEqual(result.peaks[0].note, .C)
        XCTAssertEqual(result.peaks[0].energy, 1.0)
    }

    // MARK: - RomanNumeral Public API

    func testRomanNumeralPublicInit() {
        let roman = RomanNumeral(degree: .five, accidental: .natural, quality: .major)
        XCTAssertEqual(roman.degree, .five)
        XCTAssertEqual(roman.accidental, .natural)
        XCTAssertEqual(roman.quality, .major)
        XCTAssertEqual(roman.displayString, "V")
    }

    // MARK: - SongReference Public API

    func testSongReferencePublicInit() {
        let reference = SongReference(songTitle: "Let It Be", artist: "The Beatles", detail: "1970")
        XCTAssertEqual(reference.songTitle, "Let It Be")
        XCTAssertEqual(reference.artist, "The Beatles")
        XCTAssertEqual(reference.detail, "1970")
    }

    // MARK: - ProgressionPattern Public API

    func testProgressionPatternPublicInit() {
        let numerals = [
            RomanNumeral(degree: .one, quality: .major),
            RomanNumeral(degree: .five, quality: .major),
        ]
        let examples = [SongReference(songTitle: "Test Song", artist: "Test Artist", detail: "2026")]
        let pattern = ProgressionPattern(name: "Test Pattern", numerals: numerals, description: "A test pattern", songExamples: examples)

        XCTAssertEqual(pattern.name, "Test Pattern")
        XCTAssertEqual(pattern.numerals.count, 2)
        XCTAssertEqual(pattern.description, "A test pattern")
        XCTAssertEqual(pattern.songExamples.count, 1)
    }

    // MARK: - RecognizedPattern Public API

    func testRecognizedPatternPublicAccess() {
        let numerals = [RomanNumeral(degree: .one, quality: .major)]
        let examples = [SongReference(songTitle: "Test", artist: "Test", detail: "2026")]
        let pattern = ProgressionPattern(name: "Test", numerals: numerals, description: "Test", songExamples: examples)
        let recognized = RecognizedPattern(pattern: pattern, matchType: .exact)

        XCTAssertEqual(recognized.name, "Test")
        XCTAssertEqual(recognized.description, "Test")
        XCTAssertEqual(recognized.songExamples.count, 1)
        XCTAssertEqual(recognized.matchType, .exact)
        XCTAssertEqual(recognized.displayString, "I")
    }

    // MARK: - ProgressionAnalyzer Public API

    func testProgressionAnalyzerInferKeyPublic() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .C, quality: .major),
        ]
        let key = ProgressionAnalyzer.inferKey(from: chords)

        XCTAssertNotNil(key)
        XCTAssertEqual(key?.root, .C)
        XCTAssertEqual(key?.mode, .major)
    }

    func testProgressionAnalyzerRecognizePatternPublic() {
        let chords = [
            Chord(root: .C, quality: .major),
            Chord(root: .G, quality: .major),
            Chord(root: .A, quality: .minor),
            Chord(root: .F, quality: .major),
        ]
        let key = MusicalKey(root: .C, mode: .major)
        let result = ProgressionAnalyzer.recognizePattern(progression: chords, in: key)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Pop Anthem")
        XCTAssertEqual(result?.matchType, .exact)
    }

    // MARK: - OnsetDetector Public API (0.0.8)

    func testOnsetDetectorPublicConfiguration() {
        let config = OnsetDetector.Configuration(
            windowSize: 2048,
            hopSize: 1024,
            minGapMs: 500,
            energyMultiplier: 2.0,
            energyFloor: 0.005,
            runningAverageWindow: 10
        )

        XCTAssertNotNil(config)
        XCTAssertEqual(config.windowSize, 2048)
    }

    func testOnsetDetectorPublicDefaultConfiguration() {
        let config = OnsetDetector.Configuration.default

        XCTAssertNotNil(config)
        XCTAssertEqual(config.windowSize, 2048)
        XCTAssertEqual(config.hopSize, 1024)
    }

    func testOnsetDetectorDetectOnsetsCallableExternally() {
        let buffer = generateSineWave(frequency: 440.0, sampleRate: 44100, duration: 0.5)

        let onsets = OnsetDetector.detectOnsets(buffer: buffer, sampleRate: 44100)

        XCTAssertNotNil(onsets)
    }

    // MARK: - NoiseBaseline Public API (0.0.8)

    func testNoiseBaselinePublicConstruction() {
        let chroma = [Double](repeating: 0.1, count: 12)
        let baseline = NoiseBaseline(chroma: chroma, frameCount: 10)

        XCTAssertEqual(baseline.chroma.count, 12)
        XCTAssertEqual(baseline.frameCount, 10)
    }

    func testNoiseBaselineTotalEnergyAccessible() {
        let chroma = Array(0..<12).map { Double($0) * 0.1 }
        let baseline = NoiseBaseline(chroma: chroma, frameCount: 5)

        XCTAssertGreaterThan(baseline.totalEnergy, 0)
    }

    // MARK: - NoiseCalibrator Public API (0.0.8)

    func testNoiseCalibratorCallableExternally() {
        let buffer = [Float](repeating: 0, count: Int(2.0 * 44100))

        let baseline = NoiseCalibrator.calibrateBaseline(
            buffer: buffer,
            sampleRate: 44100,
            minSilenceFrames: 5
        )

        // NoiseCalibrator should be callable; baseline may or may not be produced
        // The important thing is that it doesn't crash
        _ = baseline
        XCTAssertTrue(true)
    }

    // MARK: - Stub Classifier Provider

    private class StubClassifierProvider: ChordClassifierProvider {
        func classifyChroma(_ chroma: [Double]) -> (name: String, confidence: Double)? {
            return ("C", 0.95)
        }
    }
}
