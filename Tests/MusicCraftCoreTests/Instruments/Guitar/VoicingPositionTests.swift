import XCTest
@testable import MusicCraftCore

final class VoicingPositionTests: XCTestCase {
    func testInitialization() {
        let pos = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1,
            barres: nil,
            requiresCapo: false
        )
        XCTAssertEqual(pos.frets.count, 6)
        XCTAssertEqual(pos.fingers.count, 6)
        XCTAssertEqual(pos.baseFret, 1)
        XCTAssertNil(pos.barres)
        XCTAssertFalse(pos.requiresCapo)
    }

    func testCodableWithRequiresCapo() throws {
        let pos = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1,
            requiresCapo: false
        )
        let encoded = try JSONEncoder().encode(pos)
        let decoded = try JSONDecoder().decode(VoicingPosition.self, from: encoded)
        XCTAssertEqual(pos, decoded)
    }

    func testLegacyCapoFieldDecoding() throws {
        // Test that legacy "capo" field decodes to "requiresCapo"
        let json = """
        {
            "frets": [0, 0, 2, 2, 1, 0],
            "fingers": [0, 0, 1, 2, 1, 0],
            "baseFret": 1,
            "capo": true
        }
        """.data(using: .utf8)!

        let pos = try JSONDecoder().decode(VoicingPosition.self, from: json)
        XCTAssertTrue(pos.requiresCapo)
    }

    func testEquatable() {
        let pos1 = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1
        )
        let pos2 = VoicingPosition(
            frets: [0, 0, 2, 2, 1, 0],
            fingers: [0, 0, 1, 2, 1, 0],
            baseFret: 1
        )
        XCTAssertEqual(pos1, pos2)
    }
}
