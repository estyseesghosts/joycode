import XCTest
@testable import Joycode

final class JoycodeTests: XCTestCase {
    @MainActor
    func testRootViewCanBeConstructedWithoutAService() {
        let transport: any HTTPTransport = URLSessionHTTPTransport()
        let model = DiagnosticComposition.productionModel(transport: transport)
        let view = RootView(model: model, eventOwner: ConnectionEventOwner(connectionOwner: model), transport: transport)

        XCTAssertNotNil(view)
    }
}
