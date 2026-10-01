import XCTest
@testable import Joycode

final class JoycodeTests: XCTestCase {
    @MainActor
    func testRootViewCanBeConstructedWithoutAService() {
        let view = RootView()

        XCTAssertNotNil(view)
    }
}
