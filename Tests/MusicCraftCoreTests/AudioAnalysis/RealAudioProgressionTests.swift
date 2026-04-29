import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Real-audio progression, tempo, and key inference tests using SoundFont-generated fixtures (Phase 2).
final class RealAudioProgressionTests: XCTestCase {

    // MARK: - Progression Tests

    func testIVVIProgressionInC() throws {
        guard let fixture = loadSoundFontFixture("progression-i-iv-v-i-in-c-80bpm") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Should detect multiple chord segments
        XCTAssertGreaterThan(result.chordSegments.count, 0, "Should detect progression")

        // Expect roughly 4 segments (one per chord)
        // Allow some tolerance for onset detection variability
        XCTAssertGreaterThanOrEqual(result.chordSegments.count, 2, "Should detect at least 2 segments")

        // Check that first chord is C
        if let firstChord = result.chordSegments.first {
            let chordRoot = firstChord.chord.root.displayName
            XCTAssertEqual(chordRoot, "C", "First chord should be C")
        }
    }

    func testTempoAccuracy() throws {
        guard let fixture = loadSoundFontFixture("progression-i-iv-v-i-in-c-100bpm") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let tempoEstimates = TempoEstimator.estimateTempo(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Should produce tempo estimates
        XCTAssertGreaterThan(tempoEstimates.count, 0, "Should estimate tempo")

        // Check accuracy of top estimate
        if let topEstimate = tempoEstimates.first {
            let groundTruth = 100.0
            let error = Double(abs(topEstimate.bpm - groundTruth)) / Double(groundTruth)
            print("Tempo estimate: \(topEstimate.bpm) BPM (ground truth: \(Int(groundTruth)), error: \(String(format: "%.1f%%", error * 100)))")

            // Initial conservative threshold
            XCTAssertLessThan(error, 0.5, "Tempo error should be < 50% on first run")
        }
    }

    func testKeyInference() throws {
        guard let fixture = loadSoundFontFixture("progression-i-iv-v-i-in-c-120bpm") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Should infer key
        if let inferredKey = result.key {
            print("Inferred key: \(inferredKey.displayName)")
            // Ground truth is C major
            XCTAssertEqual(inferredKey.root.displayName, "C", "Key should be C")
        } else {
            print("Warning: no key inferred")
        }
    }

    // MARK: - Chord-Progression Metrics

    func testProgressionMetrics() throws {
        guard let fixture = loadSoundFontFixture("progression-vi-iv-i-v-in-c-100bpm") else {
            throw XCTSkip("SoundFont fixture not available")
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Create ground truth for vi-IV-I-V (Am-F-C-G in C major)
        let groundTruthSegments = [
            GroundTruth.ChordSegment(chord: "Am", startTime: 0.0, endTime: 1.0, confidence: 1.0),
            GroundTruth.ChordSegment(chord: "F", startTime: 1.0, endTime: 2.0, confidence: 1.0),
            GroundTruth.ChordSegment(chord: "C", startTime: 2.0, endTime: 3.0, confidence: 1.0),
            GroundTruth.ChordSegment(chord: "G", startTime: 3.0, endTime: 4.0, confidence: 1.0),
        ]

        let metrics = AudioAnalysisMetrics.compareChords(
            detected: result.chordSegments,
            groundTruth: groundTruthSegments,
            toleranceSeconds: 0.3  // Wider tolerance for progression timing
        )

        print("Progression metrics (vi-IV-I-V in C):")
        print("  Root accuracy: \(String(format: "%.1f%%", metrics.rootAccuracy * 100))")
        print("  Quality accuracy: \(String(format: "%.1f%%", metrics.qualityAccuracy * 100))")
        print("  Detected: \(metrics.detectedCount), Ground truth: \(metrics.groundTruthCount)")
        print("  False positives: \(metrics.falsePositives), False negatives: \(metrics.falseNegatives)")

        // Initial conservative thresholds
        XCTAssertGreaterThanOrEqual(metrics.rootAccuracy, 0.4, "Root accuracy should be at least 40%")
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

        guard FileManager.default.fileExists(atPath: wavURL.path) else {
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

            // Load ground truth if available
            var groundTruth: GroundTruth? = nil
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                do {
                    let jsonData = try Data(contentsOf: jsonURL)
                    let decoder = JSONDecoder()
                    let codable = try decoder.decode(GroundTruthCodable.self, from: jsonData)
                    groundTruth = try GroundTruthCodable.toGroundTruth(codable)
                } catch {
                    // Continue without ground truth
                }
            }

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
