import XCTest
@testable import MusicCraftCore

final class DetectedNoteTests: XCTestCase {

    func testDetectedNotePublicInit() {
        let note = DetectedNote(
            midiNote: 60,
            onsetTime: 0.5,
            duration: 0.4,
            confidence: 0.92
        )

        XCTAssertEqual(note.midiNote, 60)
        XCTAssertAlmostEqual(note.onsetTime, 0.5, accuracy: 0.001)
        XCTAssertAlmostEqual(note.duration, 0.4, accuracy: 0.001)
        XCTAssertAlmostEqual(note.confidence, 0.92, accuracy: 0.001)
    }

    func testPitchClassComputedForAllMIDINotes() {
        // Test pitch class computation for various MIDI notes
        let testCases: [(midiNote: Int, expectedPitchClass: Int)] = [
            (0, 0),    // C-1
            (60, 0),   // C4 (middle C)
            (61, 1),   // C#4
            (62, 2),   // D4
            (69, 9),   // A4
            (72, 0),   // C5
            (127, 7),  // G9 (127 % 12 = 7)
        ]

        for (midiNote, expectedPitchClass) in testCases {
            let note = DetectedNote(midiNote: midiNote, onsetTime: 0.0, duration: 0.1, confidence: 0.9)
            XCTAssertEqual(note.pitchClass, expectedPitchClass, "MIDI \(midiNote) should have pitch class \(expectedPitchClass)")
        }
    }

    func testDetectedNoteEqualityAndHashing() {
        let note1 = DetectedNote(midiNote: 60, onsetTime: 0.5, duration: 0.4, confidence: 0.9)
        let note2 = DetectedNote(midiNote: 60, onsetTime: 0.5, duration: 0.4, confidence: 0.9)
        let note3 = DetectedNote(midiNote: 61, onsetTime: 0.5, duration: 0.4, confidence: 0.9)

        XCTAssertEqual(note1, note2)
        XCTAssertNotEqual(note1, note3)

        // Test hashability
        let set: Set<DetectedNote> = [note1, note2, note3]
        XCTAssertEqual(set.count, 2)  // note1 and note2 are equal
    }

    func testDetectedNoteSendableCompiles() {
        let note = DetectedNote(midiNote: 60, onsetTime: 0.5, duration: 0.4, confidence: 0.9)

        // Verify Sendable by passing into an actor context
        Task {
            let _: DetectedNote = note
        }

        XCTAssertTrue(true)  // Just verify compilation
    }

    func testPitchClassMatchesMIDIDefinition() {
        // Pitch class should always be midiNote % 12
        for midiNote in 0...127 {
            let note = DetectedNote(midiNote: midiNote, onsetTime: 0.0, duration: 0.1, confidence: 0.9)
            XCTAssertEqual(note.pitchClass, midiNote % 12)
        }
    }
}

// Helper for approximate equality on Double
private func XCTAssertAlmostEqual(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(actual - expected), accuracy, file: file, line: line)
}
