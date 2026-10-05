import XCTest
@testable import Joycode

final class JoycodeTests: XCTestCase {
    @MainActor
    func testRootViewCanBeConstructedWithoutAService() {
        let model = DiagnosticComposition.productionModel()
        let view = RootView(model: model, eventOwner: ConnectionEventOwner(connectionOwner: model))

        XCTAssertNotNil(view)
    }
}
