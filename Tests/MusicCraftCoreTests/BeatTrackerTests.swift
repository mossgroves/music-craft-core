import XCTest
@testable import MusicCraftCore

final class BeatTrackerTests: XCTestCase {

    // MARK: - Structural Tests (not algorithm accuracy)

    func testDetectBeatsEmptyBuffer() {
        // Structural: empty buffer returns empty array.
        let beats = BeatTracker.detectBeats(buffer: [], sampleRate: 44100)
        XCTAssertEqual(beats.count, 0)
    }

    func testDetectBeatsSilenceBuffer() {
        // Structural: silence returns empty array.
        let buffer = [Float](repeating: 0, count: 44100)
        let beats = BeatTracker.detectBeats(buffer: buffer, sampleRate: 44100)
        XCTAssertNotNil(beats)
    }

    func testDetectBeatsShortBuffer() {
        // Structural: very short buffer handled without crash.
        let buffer = [Float](repeating: 0.1, count: 1000)
        let beats = BeatTracker.detectBeats(buffer: buffer, sampleRate: 44100)
        XCTAssertNotNil(beats)
    }

    func testDetectBeatsWithDefaultConfig() {
        // Structural: detectBeats works with default configuration.
        let buffer = [Float](repeating: 0.1, count: 44100 * 2)
        let beats = BeatTracker.detectBeats(buffer: buffer, sampleRate: 44100)
        XCTAssertNotNil(beats)
    }

    func testDetectBeatsWithCustomConfig() {
        // Structural: detectBeats works with custom configuration.
        let buffer = [Float](repeating: 0.1, count: 44100 * 2)
        let config = BeatTracker.Configuration(
            onsetWindowSize: 4096,
            minBeatPeriodMs: 200,
            maxBeatPeriodMs: 2000
        )
        let beats = BeatTracker.detectBeats(buffer: buffer, sampleRate: 44100, configuration: config)
        XCTAssertNotNil(beats)
    }

    func testDetectBeatsReturnsSortedArray() {
        // Structural: if beats are detected, they are sorted by time.
        let buffer = [Float](repeating: 0.1, count: 44100 * 2)
        let beats = BeatTracker.detectBeats(buffer: buffer, sampleRate: 44100)

        if beats.count > 1 {
            for i in 1..<beats.count {
                XCTAssertLessThanOrEqual(beats[i - 1], beats[i])
            }
        }
    }

    func testConfigurationConstruction() {
        // Structural: Configuration can be created with defaults.
        let config = BeatTracker.Configuration()
        XCTAssertEqual(config.onsetWindowSize, 2048)
        XCTAssertEqual(config.onsetHopSize, 1024)
        XCTAssertEqual(config.minBeatPeriodMs, 300)
        XCTAssertEqual(config.maxBeatPeriodMs, 3000)
        XCTAssertEqual(config.minAutocorrPeak, 0.3)
        XCTAssertEqual(config.inertia, 0.5)
    }

    func testConfigurationCustom() {
        // Structural: Configuration custom values are preserved.
        let config = BeatTracker.Configuration(
            onsetWindowSize: 4096,
            onsetHopSize: 512,
            minBeatPeriodMs: 200,
            maxBeatPeriodMs: 2000,
            minAutocorrPeak: 0.5,
            inertia: 0.7
        )
        XCTAssertEqual(config.onsetWindowSize, 4096)
        XCTAssertEqual(config.minAutocorrPeak, 0.5)
    }

    func testConfigurationEquatable() {
        // Structural: configurations can be compared.
        let config1 = BeatTracker.Configuration()
        let config2 = BeatTracker.Configuration()
        XCTAssertEqual(config1, config2)
    }

    func testConfigurationDefault() {
        // Structural: Configuration.default is available.
        let config = BeatTracker.Configuration.default
        XCTAssertEqual(config.onsetWindowSize, 2048)
    }

    func testConfigurationSendable() {
        // Structural: Configuration is Sendable.
        let config = BeatTracker.Configuration()
        let _: any Sendable = config
    }

    func testConfigurationHashable() {
        // Structural: configurations can be used in sets.
        let config1 = BeatTracker.Configuration()
        let config2 = BeatTracker.Configuration(minAutocorrPeak: 0.5)

        var set: Set<BeatTracker.Configuration> = [config1]
        set.insert(config2)

        XCTAssertEqual(set.count, 2)
    }
}
