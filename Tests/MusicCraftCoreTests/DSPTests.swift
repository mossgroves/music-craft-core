import XCTest
@testable import MusicCraftCore

/// DSP primitive tests. As of 0.1.0 the YIN `PitchDetector`, FFT `ChromaExtractor`, and the
/// chroma `CanonicalChromaLibrary` were removed alongside the rest of the hand-rolled DSP chord
/// path; the surviving shared primitive is `DSPUtilities` (windowing + FFT setup helpers, still
/// used by the tempo subsystem).
final class DSPTests: XCTestCase {

    // MARK: - DSP Utilities Tests

    func testHannWindowLength() {
        let window = DSPUtilities.hannWindow(length: 2048)
        XCTAssertEqual(window.count, 2048)
    }

    func testHannWindowProperties() {
        let window = DSPUtilities.hannWindow(length: 512)
        // Window should start and end near zero
        XCTAssertLessThan(window[0], 0.01)
        XCTAssertLessThan(window[511], 0.01)
        // Window should have peak near center
        let maxVal = window.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.9)
    }

    func testBlackmanWindowLength() {
        let window = DSPUtilities.blackmanWindow(length: 2048)
        XCTAssertEqual(window.count, 2048)
    }

    func testBlackmanWindowProperties() {
        let window = DSPUtilities.blackmanWindow(length: 512)
        // Window should start and end near zero
        XCTAssertLessThan(window[0], 0.01)
        XCTAssertLessThan(window[511], 0.01)
        // Window should have peak near center
        let maxVal = window.max() ?? 0
        XCTAssertGreaterThan(maxVal, 0.9)
    }
}
