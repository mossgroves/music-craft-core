import XCTest
@testable import MusicCraftCore

final class GuitarTuningTests: XCTestCase {
    func testAllCasesPresent() {
        let tunings = GuitarTuning.allCases
        XCTAssertEqual(tunings.count, 6)
        XCTAssertTrue(tunings.contains(.standard))
        XCTAssertTrue(tunings.contains(.dropD))
        XCTAssertTrue(tunings.contains(.openD))
        XCTAssertTrue(tunings.contains(.openG))
        XCTAssertTrue(tunings.contains(.dadgad))
        XCTAssertTrue(tunings.contains(.cgdgbd))
    }

    func testStandardTuningSemitones() {
        let std = GuitarTuning.standard
        XCTAssertEqual(std.semitones, [40, 45, 50, 55, 59, 64])  // E A D G B E
    }

    func testReferenceFrequenciesLength() {
        for tuning in GuitarTuning.allCases {
            let freqs = tuning.referenceFrequencies
            XCTAssertEqual(freqs.count, 6, "Tuning \(tuning) should have 6 reference frequencies")
        }
    }

    func testStandardTuningFrequencies() {
        // A4 = 440 Hz at MIDI note 69
        let std = GuitarTuning.standard
        let freqs = std.referenceFrequencies
        // MIDI note 69 is A4 = 440
        // E3 (MIDI 40) ≈ 82.41 Hz
        XCTAssertGreaterThan(freqs[0], 82.0)
        XCTAssertLessThan(freqs[0], 83.0)
    }

    func testCodableRoundTrip() throws {
        for tuning in GuitarTuning.allCases {
            let encoded = try JSONEncoder().encode(tuning)
            let decoded = try JSONDecoder().decode(GuitarTuning.self, from: encoded)
            XCTAssertEqual(tuning, decoded)
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(GuitarTuning.standard.displayName, "Standard")
        XCTAssertEqual(GuitarTuning.dropD.displayName, "Drop D")
    }

    func testShortNames() {
        XCTAssertEqual(GuitarTuning.standard.shortName, "Std")
        XCTAssertEqual(GuitarTuning.dropD.shortName, "DD")
    }
}
