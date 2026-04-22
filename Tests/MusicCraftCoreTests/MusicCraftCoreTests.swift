import XCTest
@testable import MusicCraftCore

final class MusicCraftCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(MusicCraftCore.version, "0.0.1")
    }
}
