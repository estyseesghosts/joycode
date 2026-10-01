import XCTest

final class JoycodeUITests: XCTestCase {
    func testApplicationLaunchesWithJoycodeWindow() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 5))

        // On macOS, the enclosing SwiftUI accessibility identifier is currently
        // propagated to this button. Query its visible, user-facing label while
        // retaining the diagnostic-connect identifier on the view for clients
        // that can consume it directly.
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
    }
}
