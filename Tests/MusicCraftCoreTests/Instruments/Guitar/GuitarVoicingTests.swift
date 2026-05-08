import XCTest
@testable import MusicCraftCore

final class GuitarVoicingTests: XCTestCase {
    func testInitialization() {
        let chord = Chord(root: .A, quality: .minor)
        let position = VoicingPosition(frets: [0, 0, 2, 2, 1, 0], fingers: [0, 0, 1, 2, 1, 0], baseFret: 1)
        let voicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: position)

        XCTAssertEqual(voicing.chord, chord)
        XCTAssertEqual(voicing.tuning, GuitarTuning.standard)
        XCTAssertEqual(voicing.position, position)
    }

    func testDisplayName() {
        let chord = Chord(root: .A, quality: .minor)
        let position = VoicingPosition(frets: [0, 0, 2, 2, 1, 0], fingers: [0, 0, 1, 2, 1, 0], baseFret: 1)
        let voicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: position)

        XCTAssertEqual(voicing.displayName, "Am — open")
    }

    func testDisplayNameWithBarre() {
        let chord = Chord(root: .F, quality: .major)
        let position = VoicingPosition(
            frets: [1, 3, 3, 2, 1, 1],
            fingers: [1, 3, 4, 2, 1, 1],
            baseFret: 1,
            barres: [1]
        )
        let voicing = GuitarVoicing(chord: chord, tuning: GuitarTuning.standard, position: position)
        XCTAssertEqual(voicing.displayName, "F — open")
    }

    func testIdentifiable() {
        let chord1 = Chord(root: .C, quality: .major)
        let position1 = VoicingPosition(frets: [0, 3, 2, 0, 1, 0], fingers: [0, 3, 2, 0, 1, 0], baseFret: 1)
        let voicing1 = GuitarVoicing(chord: chord1, tuning: GuitarTuning.standard, position: position1)

        let voicing2 = GuitarVoicing(chord: chord1, tuning: GuitarTuning.standard, position: position1)

        XCTAssertNotEqual(voicing1.id, voicing2.id)  // Different UUIDs
    }
}
