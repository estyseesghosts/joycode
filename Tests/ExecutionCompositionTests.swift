import XCTest
@testable import Joycode

@MainActor final class ExecutionCompositionTests: XCTestCase {
    func testAdapterErrorsKeepBusyAndUnknownDistinctFromDeclaredRejection() {
        XCTAssertEqual(ConversationComposition.interruptReply(for: .busy), .busy)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .requestFailed), .unknown)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .malformedResponse), .unknown)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .backend(statusCode: 500)), .unknown)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .unauthorized), .failed)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .notFound), .failed)
        XCTAssertEqual(ConversationComposition.interruptReply(for: .backend(statusCode: 400)), .failed)
    }

    func testLateBindingReplaysReadinessAndFailureThroughSingleFanout() async {
        let id = SessionID(rawValue: "ses-seam")
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        fanout.deliver(.connected(generation: 1))
        let store = ExecutionStatusStore(activeSessionID: { id }, connectionGeneration: { 1 }, loadActive: { [id] }, interrupt: { _ in .accepted })
        store.contextChanged()
        ConversationComposition.bindExecutionEvents(store, fanout: fanout)
        XCTAssertEqual(fanout.observerCount, 1)
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        fanout.deliver(.failed(generation: 1))
        XCTAssertFalse(store.canInterrupt)
        XCTAssertEqual(store.statusLabel, "Unknown")
    }

    func testOfflineCompositionLoadsNoSessionThenIdleAfterHydration() async {
        let fixture = OfflineUITestComposition.build()
        XCTAssertNil(fixture.model.currentContext)
        XCTAssertNotNil(fixture.executionStore.eventObservation)
        // Before any session is selected there is no execution to report on:
        // the truthful no-session presentation, with no transport and interrupt
        // disabled. It must not be an idle claim about a session.
        let noSession = await waitUntil { fixture.executionStore.phase == .noSession }
        XCTAssertTrue(noSession)
        XCTAssertEqual(fixture.executionStore.statusLabel, "No session")
        XCTAssertFalse(fixture.executionStore.canInterrupt)
        // Hydrate the seeded session exactly as `SessionView` does, then the
        // store reads the (empty) active set and rests at Idle.
        fixture.sessionStore.restoreIfNeeded()
        let idle = await waitUntil {
            fixture.sessionStore.activeSession != nil && fixture.executionStore.statusLabel == "Idle"
        }
        XCTAssertTrue(idle)
        XCTAssertEqual(fixture.executionStore.phase, .idle)
        XCTAssertFalse(fixture.executionStore.canInterrupt)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
