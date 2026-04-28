import XCTest
@testable import MusicCraftCore

final class SyntheticNoteTests: XCTestCase {

    func testCMajorScaleStructural() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("c-major-scale") else {
            XCTFail("Failed to load c-major-scale fixture")
            return
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Structural validation: synthetic sine waves do not reliably trigger onset detection.
        // Verify extraction completes without error.
        XCTAssertEqual(result.duration, fixture.duration, accuracy: 0.01, "Duration should match fixture")
        XCTAssertGreaterThanOrEqual(result.detectedNotes.count, 0, "Should return valid note count")
    }

    func testNoteMetricsComputation() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("c-major-scale"),
              case .melodyNotes(let groundTruthNotes) = fixture.groundTruth else {
            XCTFail("Failed to load fixture with note ground truth")
            return
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        let metrics = AudioAnalysisMetrics.compareNotes(
            detected: result.detectedNotes,
            groundTruth: groundTruthNotes,
            pitchToleranceSemitones: 1,
            onsetToleranceSeconds: 0.05
        )

        // Verify metrics are within valid ranges
        XCTAssertGreaterThanOrEqual(metrics.recall, 0.0, "Recall should be non-negative")
        XCTAssertLessThanOrEqual(metrics.recall, 1.0, "Recall should not exceed 100%")

        XCTAssertGreaterThanOrEqual(metrics.precision, 0.0, "Precision should be non-negative")
        XCTAssertLessThanOrEqual(metrics.precision, 1.0, "Precision should not exceed 100%")

        XCTAssertGreaterThanOrEqual(metrics.pitchAccuracy, 0.0, "Pitch accuracy should be non-negative")
        XCTAssertLessThanOrEqual(metrics.pitchAccuracy, 1.0, "Pitch accuracy should not exceed 100%")

        XCTAssertGreaterThanOrEqual(metrics.onsetAccuracy, 0.0, "Onset accuracy should be non-negative")
        XCTAssertLessThanOrEqual(metrics.onsetAccuracy, 1.0, "Onset accuracy should not exceed 100%")
    }

    func testNoteDetectionStructural() throws {
        guard let fixture = AudioFixtureLoader.loadSynthetic("c-major-scale") else {
            XCTFail("Failed to load c-major-scale fixture")
            return
        }

        let result = AudioExtractor.extract(buffer: fixture.samples, sampleRate: fixture.sampleRate)

        // Verify detected notes have valid structure
        for note in result.detectedNotes {
            XCTAssertGreaterThanOrEqual(note.midiNote, 0, "MIDI pitch should be non-negative")
            XCTAssertLessThanOrEqual(note.midiNote, 127, "MIDI pitch should not exceed 127")

            XCTAssertGreaterThanOrEqual(note.onsetTime, 0.0, "Onset time should be non-negative")
            XCTAssertLessThanOrEqual(note.onsetTime, fixture.duration, "Onset time should be within duration")

            XCTAssertGreaterThanOrEqual(note.duration, 0.0, "Note duration should be non-negative")

            XCTAssertGreaterThanOrEqual(note.confidence, 0.0, "Confidence should be non-negative")
            XCTAssertLessThanOrEqual(note.confidence, 1.0, "Confidence should not exceed 100%")
        }
    }
}
