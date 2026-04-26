import XCTest
@testable import MusicCraftCore

final class ContourNoteTests: XCTestCase {

    func testContourNotePublicInitAccessible() {
        let note = ContourNote(
            pitchSemitoneStep: 2,
            parsonsCode: .up,
            onsetTime: 0.5,
            duration: 0.4
        )

        XCTAssertEqual(note.pitchSemitoneStep, 2)
        XCTAssertEqual(note.parsonsCode, .up)
        XCTAssertAlmostEqual(note.onsetTime, 0.5, accuracy: 0.001)
        XCTAssertAlmostEqual(note.duration, 0.4, accuracy: 0.001)
    }

    func testParsonsCodeRawValues() {
        XCTAssertEqual(ParsonsCode.up.rawValue, "*")
        XCTAssertEqual(ParsonsCode.down.rawValue, "d")
        XCTAssertEqual(ParsonsCode.repeat_.rawValue, "r")
    }

    func testParsonsCodeAllCases() {
        let allCases = ParsonsCode.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertEqual(allCases[0], .up)
        XCTAssertEqual(allCases[1], .down)
        XCTAssertEqual(allCases[2], .repeat_)
    }

    func testContourNoteEqualityAndHashing() {
        let note1 = ContourNote(pitchSemitoneStep: 2, parsonsCode: .up, onsetTime: 0.5, duration: 0.4)
        let note2 = ContourNote(pitchSemitoneStep: 2, parsonsCode: .up, onsetTime: 0.5, duration: 0.4)
        let note3 = ContourNote(pitchSemitoneStep: 3, parsonsCode: .up, onsetTime: 0.5, duration: 0.4)

        XCTAssertEqual(note1, note2)
        XCTAssertNotEqual(note1, note3)

        // Test hashability by putting in a set
        let set: Set<ContourNote> = [note1, note2, note3]
        XCTAssertEqual(set.count, 2)  // note1 and note2 are equal
    }

    func testContourNoteSendableCompiles() {
        let note = ContourNote(pitchSemitoneStep: 2, parsonsCode: .up, onsetTime: 0.5, duration: 0.4)

        // Verify Sendable by passing into an actor context
        Task {
            let _: ContourNote = note
        }

        XCTAssertTrue(true)  // Just verify compilation
    }

    // MARK: - Fixture test: C major scale contour differencing

    func testFixtureContourFromCMajorScaleDetectedNotes() {
        // Fixture: C major scale (C4, D4, E4, F4, G4) with onsets at 0.0, 0.5, 1.0, 1.5, 2.0 and duration 0.4
        let detectedNotes: [DetectedNote] = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.4, confidence: 0.95),  // C4
            DetectedNote(midiNote: 62, onsetTime: 0.5, duration: 0.4, confidence: 0.95),  // D4
            DetectedNote(midiNote: 64, onsetTime: 1.0, duration: 0.4, confidence: 0.95),  // E4
            DetectedNote(midiNote: 65, onsetTime: 1.5, duration: 0.4, confidence: 0.95),  // F4
            DetectedNote(midiNote: 67, onsetTime: 2.0, duration: 0.4, confidence: 0.95),  // G4
        ]

        // Derive contour by differencing successive notes
        var contour: [ContourNote] = []

        // First note: pitchSemitoneStep=0, parsonsCode=.repeat_ (no predecessor)
        contour.append(ContourNote(
            pitchSemitoneStep: 0,
            parsonsCode: .repeat_,
            onsetTime: detectedNotes[0].onsetTime,
            duration: detectedNotes[0].duration
        ))

        // Successive notes: difference MIDI values, determine direction
        for i in 1..<detectedNotes.count {
            let step = detectedNotes[i].midiNote - detectedNotes[i - 1].midiNote
            let direction: ParsonsCode
            if step > 0 {
                direction = .up
            } else if step < 0 {
                direction = .down
            } else {
                direction = .repeat_
            }

            contour.append(ContourNote(
                pitchSemitoneStep: step,
                parsonsCode: direction,
                onsetTime: detectedNotes[i].onsetTime,
                duration: detectedNotes[i].duration
            ))
        }

        // Assertions on expected contour for C major scale (C→D→E→F→G)
        XCTAssertEqual(contour.count, 5)

        // First note: step=0, parsonsCode=.repeat_
        XCTAssertEqual(contour[0].pitchSemitoneStep, 0)
        XCTAssertEqual(contour[0].parsonsCode, .repeat_)
        XCTAssertAlmostEqual(contour[0].onsetTime, 0.0, accuracy: 0.001)

        // C→D: +2 semitones, up
        XCTAssertEqual(contour[1].pitchSemitoneStep, 2)
        XCTAssertEqual(contour[1].parsonsCode, .up)
        XCTAssertAlmostEqual(contour[1].onsetTime, 0.5, accuracy: 0.001)

        // D→E: +2 semitones, up
        XCTAssertEqual(contour[2].pitchSemitoneStep, 2)
        XCTAssertEqual(contour[2].parsonsCode, .up)
        XCTAssertAlmostEqual(contour[2].onsetTime, 1.0, accuracy: 0.001)

        // E→F: +1 semitone, up
        XCTAssertEqual(contour[3].pitchSemitoneStep, 1)
        XCTAssertEqual(contour[3].parsonsCode, .up)
        XCTAssertAlmostEqual(contour[3].onsetTime, 1.5, accuracy: 0.001)

        // F→G: +2 semitones, up
        XCTAssertEqual(contour[4].pitchSemitoneStep, 2)
        XCTAssertEqual(contour[4].parsonsCode, .up)
        XCTAssertAlmostEqual(contour[4].onsetTime, 2.0, accuracy: 0.001)
    }

    func testFixtureContourWithDescendingSequence() {
        // Fixture: descending sequence (G4, E4, C4)
        let detectedNotes: [DetectedNote] = [
            DetectedNote(midiNote: 67, onsetTime: 0.0, duration: 0.4, confidence: 0.95),  // G4
            DetectedNote(midiNote: 64, onsetTime: 0.5, duration: 0.4, confidence: 0.95),  // E4
            DetectedNote(midiNote: 60, onsetTime: 1.0, duration: 0.4, confidence: 0.95),  // C4
        ]

        var contour: [ContourNote] = []

        contour.append(ContourNote(
            pitchSemitoneStep: 0,
            parsonsCode: .repeat_,
            onsetTime: detectedNotes[0].onsetTime,
            duration: detectedNotes[0].duration
        ))

        for i in 1..<detectedNotes.count {
            let step = detectedNotes[i].midiNote - detectedNotes[i - 1].midiNote
            let direction: ParsonsCode = step > 0 ? .up : (step < 0 ? .down : .repeat_)

            contour.append(ContourNote(
                pitchSemitoneStep: step,
                parsonsCode: direction,
                onsetTime: detectedNotes[i].onsetTime,
                duration: detectedNotes[i].duration
            ))
        }

        // G→E: -3 semitones, down
        XCTAssertEqual(contour[1].pitchSemitoneStep, -3)
        XCTAssertEqual(contour[1].parsonsCode, .down)

        // E→C: -4 semitones, down
        XCTAssertEqual(contour[2].pitchSemitoneStep, -4)
        XCTAssertEqual(contour[2].parsonsCode, .down)
    }

    func testFixtureContourWithRepeatedNotes() {
        // Fixture: repeated pitch (C4, C4, D4)
        let detectedNotes: [DetectedNote] = [
            DetectedNote(midiNote: 60, onsetTime: 0.0, duration: 0.4, confidence: 0.95),  // C4
            DetectedNote(midiNote: 60, onsetTime: 0.5, duration: 0.4, confidence: 0.95),  // C4 (repeat)
            DetectedNote(midiNote: 62, onsetTime: 1.0, duration: 0.4, confidence: 0.95),  // D4
        ]

        var contour: [ContourNote] = []

        contour.append(ContourNote(
            pitchSemitoneStep: 0,
            parsonsCode: .repeat_,
            onsetTime: detectedNotes[0].onsetTime,
            duration: detectedNotes[0].duration
        ))

        for i in 1..<detectedNotes.count {
            let step = detectedNotes[i].midiNote - detectedNotes[i - 1].midiNote
            let direction: ParsonsCode = step > 0 ? .up : (step < 0 ? .down : .repeat_)

            contour.append(ContourNote(
                pitchSemitoneStep: step,
                parsonsCode: direction,
                onsetTime: detectedNotes[i].onsetTime,
                duration: detectedNotes[i].duration
            ))
        }

        // C→C: 0 semitones, repeat
        XCTAssertEqual(contour[1].pitchSemitoneStep, 0)
        XCTAssertEqual(contour[1].parsonsCode, .repeat_)

        // C→D: +2 semitones, up
        XCTAssertEqual(contour[2].pitchSemitoneStep, 2)
        XCTAssertEqual(contour[2].parsonsCode, .up)
    }
}

// Helper for approximate equality on TimeInterval
private func XCTAssertAlmostEqual(_ actual: TimeInterval, _ expected: TimeInterval, accuracy: TimeInterval, file: StaticString = #file, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(actual - expected), accuracy, file: file, line: line)
}
