import XCTest
@testable import MusicCraftCore

final class MusicCraftCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(musicCraftCoreVersion, "0.0.9")
    }
}
