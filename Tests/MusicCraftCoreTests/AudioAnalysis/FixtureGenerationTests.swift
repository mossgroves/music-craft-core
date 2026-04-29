import XCTest

/// Test for generating SoundFont fixtures. Disabled by default; run with MCC_GENERATE_FIXTURES=1 env var.
final class FixtureGenerationTests: XCTestCase {

    func testGenerateAllFixtures() throws {
        // Skip unless explicitly enabled
        guard ProcessInfo.processInfo.environment["MCC_GENERATE_FIXTURES"] == "1" else {
            throw XCTSkip("Fixture generation disabled. Set MCC_GENERATE_FIXTURES=1 to enable.")
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
