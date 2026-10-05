import XCTest
@testable import Joycode

/// R10 permission composition coverage (offline only).
///
/// - The composition-owned transport adapter keeps declared rejections
///   distinct from honest absence (`notFound`) and ambiguity (`unknown`).
/// - Late fanout binding replays readiness/failure through the single fanout.
/// - Permission events only invalidate (authoritative rereads reconcile);
///   unrelated families and other sessions never touch permission facts.
/// - The DEBUG offline fixture seeds one pending permission for session A;
///   asking/replying flows through the fanout while the authoritative load
///   and the reply-triggered reread own the list.
///
/// No live, service, provider, or lifecycle use.
@MainActor final class PermissionCompositionTests: XCTestCase {
    // MARK: - Adapter classification

    func testAdapterErrorsKeepNotFoundRejectedAndUnknownDistinct() {
        XCTAssertEqual(ConversationComposition.permissionReply(for: .notFound), .notFound)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .unauthorized), .rejected)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .backend(statusCode: 400)), .rejected)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .requestFailed), .unknown)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .malformedResponse), .unknown)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .backend(statusCode: 500)), .unknown)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .backend(statusCode: 409)), .unknown)
        XCTAssertEqual(ConversationComposition.permissionReply(for: .notConnected), .unknown)
    }

    func testDecisionMappingAdmitsOnlyOnceAndReject() {
        // P1 exposes no permanent auto-approval: only once/reject reach the wire.
        XCTAssertEqual(ConversationComposition.permissionDecision(.once), .once)
        XCTAssertEqual(ConversationComposition.permissionDecision(.reject), .reject)
    }

    // MARK: - Late fanout binding

    func testLateBindingReplaysReadinessAndFailureThroughSingleFanout() async {
        let id = SessionID(rawValue: "ses-seam")
        let request = PermissionRequest(
            id: "per_seam_1",
            sessionID: id.rawValue,
            action: "edit",
            resources: ["/tmp/a"],
            save: nil,
            metadata: nil,
            source: nil,
            message: nil
        )
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        fanout.deliver(.connected(generation: 1))
        let store = PermissionStore(
            activeSessionID: { id },
            connectionGeneration: { 1 },
            load: { _ in [request] },
            reply: { _, _, _ in .accepted }
        )
        store.contextChanged()
        ConversationComposition.bindPermissionEvents(store, fanout: fanout)
        XCTAssertEqual(fanout.observerCount, 1)
        let loaded = await waitUntil { !store.pending.isEmpty }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.pending.map(\.id), ["per_seam_1"])
        XCTAssertEqual(store.provenance?.session, id)
        XCTAssertEqual(store.provenance?.generation, 1)
        XCTAssertTrue(store.canReply("per_seam_1"))
        // Stream failure disables approval but retains facts; it never claims
        // settlement by clearing the list.
        fanout.deliver(.failed(generation: 1))
        XCTAssertTrue(store.isStale)
        XCTAssertFalse(store.canReply("per_seam_1"))
        XCTAssertEqual(store.pending.map(\.id), ["per_seam_1"])
    }

    // MARK: - Event classification

    func testPermissionEventsInvalidateWhileUnrelatedEventsAreIgnored() async throws {
        let id = SessionID(rawValue: "ses-1")
        let request = PermissionRequest(
            id: "per_1",
            sessionID: id.rawValue,
            action: "edit",
            resources: ["/tmp/a"],
            save: nil,
            metadata: nil,
            source: nil,
            message: nil
        )
        let script = PermissionLoadScript(requests: [request])
        let store = PermissionStore(
            activeSessionID: { id },
            connectionGeneration: { 1 },
            load: { _ in await script.run() },
            reply: { _, _, _ in .accepted }
        )
        store.refresh()
        let loaded = await waitUntil { await script.calls >= 1 && !store.pending.isEmpty }
        XCTAssertTrue(loaded)
        let reads = await script.calls
        // `permission.asked` for the active session invalidates; the reread
        // reconciles. The event itself never merges into the list.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked",
            id: "evt-asked-1",
            data: "{\"sessionID\":\"ses-1\",\"id\":\"per_1\"}"
        )))
        let reread = await waitUntil { await script.calls == reads + 1 }
        XCTAssertTrue(reread)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        // `permission.replied` likewise reconciles by reread only.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.replied",
            id: "evt-replied-1",
            data: "{\"sessionID\":\"ses-1\",\"requestID\":\"per_1\",\"reply\":\"once\"}"
        )))
        let rereadAgain = await waitUntil { await script.calls == reads + 2 }
        XCTAssertTrue(rereadAgain)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        // Another store's family and another session's permission event never
        // touch this session's permission facts.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.started",
            id: "evt-exec-1",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked",
            id: "evt-asked-other",
            data: "{\"sessionID\":\"ses-other\",\"id\":\"per_9\"}"
        )))
        for _ in 0..<20 { await Task.yield() }
        let ignoredReads = await script.calls
        XCTAssertEqual(ignoredReads, reads + 2)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        // A permission event that cannot be attributed reconciles by reread
        // rather than guessing; the retained list is untouched until the read.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked",
            id: "evt-asked-bare",
            data: "{}"
        )))
        let reconciled = await waitUntil { await script.calls == reads + 3 }
        XCTAssertTrue(reconciled)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
    }

    // MARK: - Offline fixture flow

    func testOfflineFixturePermissionReplyClearsPendingRequest() async {
        let fixture = OfflineUITestComposition.build()
        // Single composition-owned fanout binding; the view creates none.
        XCTAssertNotNil(fixture.permissionStore.eventObservation)
        XCTAssertEqual(fixture.eventOwner.fanout.observerCount, 3)
        // Hydrate the seeded session exactly as `SessionView` does; the
        // fixture backend lists one pending permission for session A.
        fixture.sessionStore.restoreIfNeeded()
        let appeared = await waitUntil { !fixture.permissionStore.pending.isEmpty }
        XCTAssertTrue(appeared)
        XCTAssertEqual(fixture.permissionStore.pending.map(\.id), ["per_fixture_allow"])
        XCTAssertEqual(fixture.permissionStore.provenance?.session, SessionID(rawValue: "ses-fixture-a"))
        XCTAssertTrue(fixture.permissionStore.canReply("per_fixture_allow"))
        // `permission.asked` through the fanout reconciles through the
        // authoritative read; the seeded request remains pending.
        OfflineUITestComposition.deliverPermissionAsked(
            sessionID: SessionID(rawValue: "ses-fixture-a"),
            requestID: "per_fixture_allow",
            action: "edit",
            to: fixture.eventOwner.fanout
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.permissionStore.pending.map(\.id), ["per_fixture_allow"])
        // Allow once: the reply is accepted, then the authoritative reread
        // (not the event) clears the list. Absence reports no success claim.
        fixture.permissionStore.reply(requestID: "per_fixture_allow", decision: .once)
        let cleared = await waitUntil { fixture.permissionStore.pending.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertNil(fixture.permissionStore.lastError)
        XCTAssertFalse(fixture.permissionStore.canReply("per_fixture_allow"))
        // `permission.replied` through the fanout reconciles the empty list
        // without inventing settlement.
        OfflineUITestComposition.deliverPermissionReplied(
            sessionID: SessionID(rawValue: "ses-fixture-a"),
            requestID: "per_fixture_allow",
            decision: "once",
            to: fixture.eventOwner.fanout
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fixture.permissionStore.pending.isEmpty)
        XCTAssertNil(fixture.permissionStore.lastError)
    }

    // MARK: - Helpers

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    private func envelope(type: String, id: String, data: String) throws -> EventEnvelope {
        let json = "{\"id\":\"\(id)\",\"type\":\"\(type)\",\"created\":1,\"data\":\(data)}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }
}

// MARK: - Test doubles

private actor PermissionLoadScript {
    private(set) var calls = 0
    private let requests: [PermissionRequest]

    init(requests: [PermissionRequest]) { self.requests = requests }

    func run() async -> [PermissionRequest] {
        calls += 1
        return requests
    }
}
