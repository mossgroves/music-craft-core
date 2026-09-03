import XCTest
@testable import MusicCraftCore

final class MusicCraftCoreTests: XCTestCase {
    /// The version string moves with every release, and this assertion moves with it: it read
    /// "0.1.8" through 0.1.9 ... 0.1.15 because nobody updated Version.swift at those tags, so the
    /// pin was asserting a stale value. Since 0.1.16 the release commit updates both together
    /// (the pre-push hook makes forgetting this test impossible; forgetting Version.swift is
    /// still on the release step).
    func testVersionIsSet() {
        XCTAssertEqual(musicCraftCoreVersion, "0.1.17")
    }
}
