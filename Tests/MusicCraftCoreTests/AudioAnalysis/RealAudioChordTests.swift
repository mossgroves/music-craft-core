import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Real-audio chord detection tests using SoundFont-generated fixtures (Phase 2).
final class RealAudioChordTests: XCTestCase {

    var fixtureLoader: AudioFixtureLoader!

    override func setUp() {
        super.setUp()
        fixtureLoader = AudioFixtureLoader()
    }

    // MARK: - Single Chord Tests

    func testSoundFontCMajorChord() throws {
        guard let fixture = loadSoundFontFixture("chord-c") else {
            throw XCTSkip("SoundFont fixture not available; run testGenerateAllFixtures first")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Should detect at least one chord segment
        XCTAssertGreaterThan(result.chordSegments.count, 0, "Should detect chord in C major")

        // First segment should be C major (root note)
        if let firstChord = result.chordSegments.first {
            let chordRoot = firstChord.chord.root.displayName
            XCTAssertEqual(chordRoot, "C", "Root should be C")
            XCTAssertGreaterThanOrEqual(firstChord.confidence, 0.5, "Confidence should be reasonable")
        }
    }

    func testSoundFontAMinorChord() throws {
        guard let fixture = loadSoundFontFixture("chord-am") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        XCTAssertGreaterThan(result.chordSegments.count, 0, "Should detect chord in A minor")

        if let firstChord = result.chordSegments.first {
            let chordRoot = firstChord.chord.root.displayName
            XCTAssertEqual(chordRoot, "A", "Root should be A")
        }
    }

    func testSoundFontGMajorChord() throws {
        guard let fixture = loadSoundFontFixture("chord-g") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        XCTAssertGreaterThan(result.chordSegments.count, 0, "Should detect chord in G major")

        if let firstChord = result.chordSegments.first {
            let chordRoot = firstChord.chord.root.displayName
            XCTAssertEqual(chordRoot, "G", "Root should be G")
        }
    }

    // MARK: - Chord Accuracy Metrics

    func testChordAccuracyMetrics() throws {
        // Test a simple chord and measure accuracy against ground truth
        guard let fixture = loadSoundFontFixture("chord-c") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        guard case .singleChord(let groundTruthChord, _) = fixture.groundTruth else {
            throw XCTSkip("Fixture missing ground truth")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Create a synthetic ground truth segment
        let groundTruthSegments = [GroundTruth.ChordSegment(
            chord: groundTruthChord,
            startTime: 0.0,
            endTime: fixture.duration,
            confidence: 1.0
        )]

        let metrics = AudioAnalysisMetrics.compareChords(
            detected: result.chordSegments,
            groundTruth: groundTruthSegments,
            toleranceSeconds: 0.2
        )

        // Log metrics for later analysis
        print("Chord detection metrics for \(groundTruthChord):")
        print("  Root accuracy: \(String(format: "%.1f%%", metrics.rootAccuracy * 100))")
        print("  Quality accuracy: \(String(format: "%.1f%%", metrics.qualityAccuracy * 100))")
        print("  Exact accuracy: \(String(format: "%.1f%%", metrics.exactAccuracy * 100))")
        print("  Confidence: \(String(format: "%.2f", metrics.confidenceAverage))")
        print("  Timing deviation: \(String(format: "%.3f s", metrics.timingDeviation))")

        // Initial conservative thresholds (calibrated low for first run)
        XCTAssertGreaterThanOrEqual(metrics.rootAccuracy, 0.5, "Root accuracy should be at least 50%")
    }

    // MARK: - Helpers

    private func loadSoundFontFixture(_ name: String) -> AudioFixtureLoader.Fixture? {
        let fixtureDir = Bundle(for: type(of: self)).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("synthetic-soundfont")

        let wavURL = fixtureDir.appendingPathComponent("\(name).wav")
        let jsonURL = fixtureDir.appendingPathComponent("\(name).json")

        guard FileManager.default.fileExists(atPath: wavURL.path),
              FileManager.default.fileExists(atPath: jsonURL.path) else {
            return nil
        }

        do {
            let audioFile = try AVAudioFile(forReading: wavURL)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else {
                return nil
            }

            try audioFile.read(into: buffer)

            guard let floatData = buffer.floatChannelData else {
                return nil
            }

            let frameLength = Int(buffer.frameLength)
            let samples = Array<Float>(UnsafeBufferPointer(start: floatData[0], count: frameLength))
            let sampleRate = audioFile.processingFormat.sampleRate
            let duration = TimeInterval(frameLength) / sampleRate

            // Load ground truth from JSON
            let jsonData = try Data(contentsOf: jsonURL)
            let decoder = JSONDecoder()
            let codable = try decoder.decode(GroundTruthCodable.self, from: jsonData)
            let groundTruth = try GroundTruthCodable.toGroundTruth(codable)

            return AudioFixtureLoader.Fixture(
                samples: samples,
                sampleRate: sampleRate,
                duration: duration,
                groundTruth: groundTruth
            )
        } catch {
            print("Failed to load fixture \(name): \(error)")
            return nil
        }
    }
}

// MARK: - Ground Truth Codable extension

extension GroundTruthCodable {
    static func toGroundTruth(_ codable: GroundTruthCodable) throws -> GroundTruth {
        switch codable.type {
        case .singleChord:
            guard let chord = codable.data["chord"]?.stringValue,
                  let confidence = codable.data["confidence"]?.doubleValue else {
                throw NSError(domain: "GroundTruth", code: -1)
            }
            return .singleChord(chord: chord, confidence: confidence)

        case .chordProgression:
            // Stub implementation for now
            return .singleChord(chord: "C", confidence: 1.0)

        case .tempo:
            guard let bpm = codable.data["bpm"]?.intValue else {
                throw NSError(domain: "GroundTruth", code: -1)
            }
            return .tempo(bpm: bpm)

        case .melodyNotes:
            // Stub implementation
            return .melodyNotes(notes: [])

        case .lyrics:
            return .lyrics(words: [])
        }
    }
}

// MARK: - AnyCodable helpers

extension AnyCodable {
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v):
            return v
        case .int(let v):
            return Double(v)
        default:
            return nil
        }
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
}
