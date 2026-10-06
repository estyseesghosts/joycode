import XCTest

/// UI tests drive the real Joycode.app in a live GUI session.
///
/// Environment prerequisite (not fixable in-repo): the Mac must have an
/// unlocked, awake GUI session with the display on while these tests run.
/// If the screen is locked or the display is asleep, the app under test
/// still launches (a fresh process per test, visible in the accessibility
/// hierarchy as `Application title: 'Joycode'`), but the WindowServer maps
/// no windows, so every `app.windows` wait fails even though the app itself
/// is healthy. That signature (app alive, zero windows, fresh pid per test)
/// means the session, not the app. The test-runner host additionally needs
/// Accessibility/Automation approval on first run.
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

    // MARK: - Offline fixture (DEBUG-only, opt-in via launch argument)

    /// Rename edit flows through the local fixture and the authoritative
    /// title is displayed.
    func testOfflineFixtureRenamePublishesAuthoritativeTitle() {
        let app = makeOfflineFixtureApp()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // Session A restores automatically from the seeded fixture preferences.
        let editor = app.textFields["Session title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let initialTitle = expectation(
            for: NSPredicate(format: "value == %@", "Fixture Session A"),
            evaluatedWith: editor,
            handler: nil
        )
        wait(for: [initialTitle], timeout: 15)

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Fixture Session Renamed")

        let renameButton = app.buttons["Rename"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.click()

        XCTAssertTrue(app.staticTexts["Fixture Session Renamed"].waitForExistence(timeout: 15))
    }

    /// Choosing another root selects it (accessibility selected state) and the
    /// session directory scope follows the newly active session.
    func testOfflineFixtureRootSelectionUpdatesScope() {
        let app = makeOfflineFixtureApp()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let firstRoot = app.buttons["Fixture Session A"]
        XCTAssertTrue(firstRoot.waitForExistence(timeout: 15))
        let secondRoot = app.buttons["Fixture Session B"]
        XCTAssertTrue(secondRoot.waitForExistence(timeout: 15))

        secondRoot.click()

        XCTAssertTrue(app.staticTexts["Fixture Session B"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["/fixture"].waitForExistence(timeout: 15))

        let selected = expectation(
            for: NSPredicate(format: "value == %@", "selected"),
            evaluatedWith: secondRoot,
            handler: nil
        )
        wait(for: [selected], timeout: 15)
        let deselected = expectation(
            for: NSPredicate(format: "value == %@", "not-selected"),
            evaluatedWith: firstRoot,
            handler: nil
        )
        wait(for: [deselected], timeout: 15)
    }

    /// Agent and model picks from the injected catalogs confirm locally.
    func testOfflineFixtureAgentAndModelSelectionConfirms() {
        let app = makeOfflineFixtureApp()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Catalog: /fixture"].waitForExistence(timeout: 15))

        let agentPicker = app.popUpButtons["Primary agent"]
        XCTAssertTrue(agentPicker.waitForExistence(timeout: 15))
        let agentReady = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: agentPicker)
        wait(for: [agentReady], timeout: 15)
        agentPicker.click()
        let planItem = app.menuItems["Plan"]
        XCTAssertTrue(planItem.waitForExistence(timeout: 5))
        planItem.click()
        let agentConfirmed = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "Plan"),
            evaluatedWith: agentPicker,
            handler: nil
        )
        wait(for: [agentConfirmed], timeout: 15)

        let modelPicker = app.popUpButtons["Model"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 15))
        modelPicker.click()
        let gptItem = app.menuItems["GPT (openai)"]
        XCTAssertTrue(gptItem.waitForExistence(timeout: 5))
        gptItem.click()
        let modelConfirmed = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "GPT"),
            evaluatedWith: modelPicker,
            handler: nil
        )
        wait(for: [modelConfirmed], timeout: 15)
    }

    // MARK: - Helpers

    func testOfflineFixtureMultilineSendAndAuthoritativeHistoryRefresh() {
        let app = makeOfflineFixtureApp()
        app.launch()
        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("Offline first line\nOffline second line")
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 15)
        send.click()
        let cleared = expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: editor)
        wait(for: [cleared], timeout: 15)
        app.buttons["Refresh history"].click()
        XCTAssertTrue(app.staticTexts["Offline first line\nOffline second line"].waitForExistence(timeout: 15))
    }

    /// R08: the fixture plays readiness and a durable `session.inbox.delivered`
    /// event through the production fanout, so the transcript updates with no
    /// manual Refresh and reports live state only after readiness.
    func testOfflineFixtureSendUpdatesTranscriptFromEventsWithoutRefresh() {
        let app = makeOfflineFixtureApp()
        app.launch()
        let live = app.staticTexts["Live · Most recent 50"]
        XCTAssertTrue(live.waitForExistence(timeout: 15))

        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("Event driven line")
        let send = app.buttons["Send message"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 15)
        send.click()
        XCTAssertTrue(app.staticTexts["Event driven line"].waitForExistence(timeout: 15))
    }

    /// R09: a local run becomes interruptible, then server-shaped fixture
    /// facts confirm interruption. This is not a live/provider check.
    func testOfflineFixtureInterruptConfirmsExecutionStatus() {
        let app = makeOfflineFixtureApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Execution: Idle"].waitForExistence(timeout: 15))
        let editor = app.textViews["Message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeText("Fixture execution to interrupt")
        let send = app.buttons["Send message"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
        wait(for: [ready], timeout: 15)
        send.click()
        XCTAssertTrue(app.staticTexts["Execution: Working"].waitForExistence(timeout: 15))
        let interrupt = app.buttons["Interrupt execution"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        let interruptReady = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: interrupt)
        wait(for: [interruptReady], timeout: 15)
        interrupt.click()
        XCTAssertTrue(app.staticTexts["Execution: Interrupted"].waitForExistence(timeout: 15))
    }

    /// R10: the fixture seeds one pending permission for session A; allowing it
    /// once clears the row through an authoritative reread (no manual
    /// Refresh). This is not a live/provider check.
    func testOfflineFixturePermissionAllowOnceClearsPendingRequest() {
        let app = makeOfflineFixtureApp()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let allowOnce = app.buttons["Allow once"]
        XCTAssertTrue(allowOnce.waitForExistence(timeout: 15))
        let actionable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: allowOnce)
        XCTAssertEqual(XCTWaiter.wait(for: [actionable], timeout: 15), .completed)
        allowOnce.click()

        XCTAssertTrue(app.staticTexts["No pending permissions."].waitForExistence(timeout: 15))
    }

    /// Launches with the DEBUG-only offline fixture. Normal production
    /// launches never pass this argument; Release builds cannot honor it.
    private func makeOfflineFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--joycode-offline-ui-fixture"]
        return app
    }
}
