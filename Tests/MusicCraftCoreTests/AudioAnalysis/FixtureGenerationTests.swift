import XCTest

/// Test for generating SoundFont fixtures. Disabled by default; run with MCC_GENERATE_FIXTURES=1 env var.
final class FixtureGenerationTests: XCTestCase {

    func testGenerateAllFixtures() throws {
        // Skip unless SoundFont experiment is explicitly enabled
        guard ProcessInfo.processInfo.environment["MCC_SOUNDFONT_EXPERIMENT"] == "1" else {
            throw XCTSkip("SoundFont experiment opt-in required. Set MCC_SOUNDFONT_EXPERIMENT=1 to enable. Note: SoundFont-generated audio is not a valid baseline for AudioExtractor (see Phase 2.5 notes).")
        }

        // Output directory: Tests/MusicCraftCoreTests/AudioAnalysis/Fixtures/synthetic-soundfont
        let fileManager = FileManager.default
        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        let fixtureDir = testBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AudioAnalysis")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("synthetic-soundfont")

        print("Generating fixtures to: \(fixtureDir.path)")

        // Generate all fixtures
        try FixtureGenerator.generateAllFixtures(outputDirectory: fixtureDir)

        // Verify output
        var generatedCount = 0
        if let contents = try? fileManager.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil) {
            let wavFiles = contents.filter { $0.pathExtension == "wav" }
            generatedCount = wavFiles.count
        }

        print("Generated \(generatedCount) WAV fixtures")
        XCTAssertGreaterThan(generatedCount, 0, "Should generate at least one fixture")
    }
}
