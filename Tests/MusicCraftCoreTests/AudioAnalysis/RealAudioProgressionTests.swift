import XCTest
import AVFoundation
@testable import MusicCraftCore

/// Real-audio progression, tempo, and key inference tests using SoundFont-generated fixtures (Phase 2).
final class RealAudioProgressionTests: XCTestCase {

    // MARK: - Progression Tests

    func testIVVIProgressionInC() throws {
        throw XCTSkip("Progression tests deferred to Phase 3 (GuitarSet integration). Single-chord fixtures don't exercise progression segmentation.")
    }

    func testTempoAccuracy() throws {
        throw XCTSkip("Progression tests deferred to Phase 3 (GuitarSet integration). Single-chord fixtures don't exercise progression segmentation.")
    }

    func testKeyInference() throws {
        throw XCTSkip("Progression tests deferred to Phase 3 (GuitarSet integration). Single-chord fixtures don't exercise progression segmentation.")
    }

    // MARK: - Chord-Progression Metrics

    func testProgressionMetrics() throws {
        throw XCTSkip("Progression tests deferred to Phase 3 (GuitarSet integration). Single-chord fixtures don't exercise progression segmentation.")
    }
}
