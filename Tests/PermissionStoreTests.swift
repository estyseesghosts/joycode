import Foundation
import XCTest
@testable import Joycode

// MARK: - Permission store tests (R10, offline)
//
// Deterministic tests over controlled `load` / `reply` closures and synthetic
// fanout signals: authoritative pending reads with provenance, event-only
// invalidation (never merge/remove), duplicate suppression, slow-read epochs
// with follow-up, session/generation replacement including A-B-A and queued
// reply capture, stream/read failure honesty, and the full reply matrix
// (accepted / reject choice / honest 404 / declared rejection / lost reply
// with no re-POST). No live, service, or provider use.

final class PermissionStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor private func waitUntil(_ condition: @escaping @MainActor @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func request(
        id: String = "per_1",
        session: String = "ses-1",
        action: String = "execute",
        resources: [String] = ["ls"]
    ) -> PermissionRequest {
        PermissionRequest(
            id: id,
            sessionID: session,
            action: action,
            resources: resources,
            save: nil,
            metadata: nil,
            source: nil,
            message: nil
        )
    }

    private func envelope(
        type: String,
        id: String = "evt-1",
        data: String
    ) throws -> EventEnvelope {
        let json = "{\"id\":\"\(id)\",\"type\":\"\(type)\",\"created\":1,\"data\":\(data)}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    @MainActor private func makeStore(
        session: PermissionSessionBox? = nil,
        connection: PermissionConnectionBox? = nil,
        load: ScriptedPermissionLoad,
        reply: ScriptedPermissionReply
    ) -> PermissionStore {
        let sessionBox = session ?? PermissionSessionBox(current: SessionID(rawValue: "ses-1"))
        let connectionBox = connection ?? PermissionConnectionBox(generation: 1)
        return PermissionStore(
            activeSessionID: { sessionBox.current },
            connectionGeneration: { connectionBox.generation },
            load: { id in try await load.run(id) },
            reply: { session, requestID, choice in await reply.call(session, requestID, choice) }
        )
    }

    // MARK: Pending-list reads and provenance

    @MainActor func testInitialLoadPublishesPendingWithProvenance() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let listed = await waitUntil { store.pending.map(\.id) == ["per_1"] }
        XCTAssertTrue(listed)
        XCTAssertTrue(store.hasPending)
        XCTAssertTrue(store.canReply("per_1"))
        XCTAssertFalse(store.isStale)
        let provenance = try XCTUnwrap(store.provenance)
        XCTAssertEqual(provenance.session, SessionID(rawValue: "ses-1"))
        XCTAssertEqual(provenance.generation, 1)
        XCTAssertEqual(provenance.readEpoch, 1)
        let sessions = await load.requestedSessions()
        XCTAssertEqual(sessions, [SessionID(rawValue: "ses-1")])
    }

    @MainActor func testDuplicateRequestIDsDeduplicated() async {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1"), request(id: "per_1"), request(id: "per_2")])
        let listed = await waitUntil { !store.isLoading }
        XCTAssertTrue(listed)
        XCTAssertEqual(store.pending.map(\.id), ["per_1", "per_2"])
    }

    @MainActor func testUnattributableListEntryFailsReadClosed() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let listed = await waitUntil { store.pending.map(\.id) == ["per_1"] }
        XCTAssertTrue(listed)
        // One entry owned by another session fails the whole read: prior facts
        // are retained, marked stale, never replaced by the mixed list.
        store.refresh()
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_1"), request(id: "per_x", session: "ses-other")])
        let stale = await waitUntil { store.isStale }
        XCTAssertTrue(stale)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        let provenance = try XCTUnwrap(store.provenance)
        XCTAssertEqual(provenance.readEpoch, 1)
    }

    @MainActor func testNilSessionIssuesNoTransport() async {
        let sessionBox = PermissionSessionBox(current: nil)
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(session: sessionBox, load: load, reply: reply)
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        let startedReads = await load.count()
        XCTAssertEqual(startedReads, 0)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.hasPending)
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        let replyCalls = await reply.count()
        XCTAssertEqual(replyCalls, 0)
    }

    @MainActor func testNilConnectionDisablesTransport() async {
        let connectionBox = PermissionConnectionBox(generation: nil)
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(connection: connectionBox, load: load, reply: reply)
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        let startedReads = await load.count()
        XCTAssertEqual(startedReads, 0)
        XCTAssertFalse(store.canReply("per_1"))
    }

    // MARK: Context replacement, races, queued capture

    @MainActor func testContextResetClearsImmediatelyAndIgnoresStaleLoad() async throws {
        let sessionBox = PermissionSessionBox(current: SessionID(rawValue: "ses-A"))
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(session: sessionBox, load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(session: "ses-A")])
        let listed = await waitUntil { store.pending.map(\.id) == ["per_1"] }
        XCTAssertTrue(listed)
        sessionBox.current = SessionID(rawValue: "ses-B")
        store.contextChanged()
        // The old display clears synchronously; the stale reply cannot publish.
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertNil(store.provenance)
        await load.waitUntilEntered(1)
        await load.resolve(0, [request(id: "per_stale", session: "ses-A")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.pending.isEmpty)
        await load.resolve(1, [request(id: "per_2", session: "ses-B")])
        let relisted = await waitUntil { store.pending.map(\.id) == ["per_2"] }
        XCTAssertTrue(relisted)
        let provenance = try XCTUnwrap(store.provenance)
        XCTAssertEqual(provenance.session, SessionID(rawValue: "ses-B"))
    }

    @MainActor func testSessionABAReturnIgnoresStaleCompletions() async {
        let sessionBox = PermissionSessionBox(current: SessionID(rawValue: "ses-A"))
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(session: sessionBox, load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        sessionBox.current = SessionID(rawValue: "ses-B")
        store.contextChanged()
        await load.waitUntilEntered(1)
        // A-B-A: returning to the original session still invalidates both
        // in-flight reads via the local epoch.
        sessionBox.current = SessionID(rawValue: "ses-A")
        store.contextChanged()
        await load.waitUntilEntered(2)
        await load.resolve(0, [request(id: "per_old0", session: "ses-A")])
        await load.resolve(1, [request(id: "per_old1", session: "ses-B")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.pending.isEmpty)
        await load.resolve(2, [request(id: "per_new", session: "ses-A")])
        let listed = await waitUntil { store.pending.map(\.id) == ["per_new"] }
        XCTAssertTrue(listed)
    }

    @MainActor func testQueuedReplyCapturesOriginalContext() async {
        let sessionBox = PermissionSessionBox(current: SessionID(rawValue: "ses-A"))
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.holdNext()
        let store = makeStore(session: sessionBox, load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(session: "ses-A")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        // The context moves before the queued transport runs. The reply task
        // must drop the stale dispatch, never answering for ses-A from ses-B.
        sessionBox.current = SessionID(rawValue: "ses-B")
        store.contextChanged()
        await load.waitUntilEntered(1)
        await reply.release(.accepted)
        for _ in 0..<20 { await Task.yield() }
        let replyCalls = await reply.count()
        XCTAssertEqual(replyCalls, 0)
        XCTAssertTrue(store.pending.isEmpty)
        await load.resolve(1, [request(id: "per_2", session: "ses-B")])
        let relisted = await waitUntil { store.pending.map(\.id) == ["per_2"] }
        XCTAssertTrue(relisted)
    }

    @MainActor func testConnectionReplacementIgnoresOldGenerationSignals() async throws {
        let connectionBox = PermissionConnectionBox(generation: 1)
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(connection: connectionBox, load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        connectionBox.generation = 2
        store.contextChanged()
        await load.waitUntilEntered(1)
        // Old-generation signals are ignored: no stale flag, no reset.
        store.receive(.failed(generation: 1))
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.isStale)
        XCTAssertTrue(store.pending.isEmpty)
        await load.resolve(1, [request()])
        let relisted = await waitUntil { store.hasPending }
        XCTAssertTrue(relisted)
        let provenance = try XCTUnwrap(store.provenance)
        XCTAssertEqual(provenance.generation, 2)
    }

    @MainActor func testDuplicateContextChangeIssuesNoTransport() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        store.contextChanged()
        for _ in 0..<20 { await Task.yield() }
        let readCount = await load.count()
        XCTAssertEqual(readCount, 1)
    }

    // MARK: Events invalidate only

    @MainActor func testContextChangeBeforePublisherHopCannotAnswerOldRequest() async {
        let session = PermissionSessionBox(current: SessionID(rawValue: "ses-1"))
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(session: session, load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let ready = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(ready)
        session.current = SessionID(rawValue: "ses-2")
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        XCTAssertTrue(store.pending.isEmpty)
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let calls = await reply.count()
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testAnonymousRequestInInjectedListFailsClosed() async {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "")])
        let failed = await waitUntil { store.isStale }
        XCTAssertTrue(failed)
        XCTAssertTrue(store.pending.isEmpty)
        store.reply(requestID: "", decision: .once)
        let calls = await reply.count()
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testReplySupersedesReadThatBeganBeforeReply() async {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.accepted)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request()])
        let ready = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(ready)
        store.refresh()
        await load.waitUntilEntered(1)
        store.reply(requestID: "per_1", decision: .once)
        await load.waitUntilEntered(2)
        await load.resolve(1, [request()])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        let calls = await reply.count()
        XCTAssertEqual(calls, 1)
        await load.resolve(2, [])
        let cleared = await waitUntil { !store.isLoading && store.pending.isEmpty }
        XCTAssertTrue(cleared)
    }

    @MainActor func testAskedEventInvalidatesWithoutMerging() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        // The event carries a full new request inline; the store must never
        // merge it. Only the follow-up read may change the list.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked",
            id: "evt-asked",
            data: "{\"sessionID\":\"ses-1\",\"id\":\"per_9\",\"action\":\"execute\",\"resources\":[\"rm\"]}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_1"), request(id: "per_9", resources: ["rm"])])
        let updated = await waitUntil { store.pending.map(\.id) == ["per_1", "per_9"] }
        XCTAssertTrue(updated)
        let reads = await load.count()
        XCTAssertEqual(reads, 2)
    }

    @MainActor func testRepliedEventNeverRemoves() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        // The reply event names the request, but removal belongs to the
        // authoritative read alone: the entry stays until the reread lands.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.replied",
            id: "evt-replied",
            data: "{\"sessionID\":\"ses-1\",\"requestID\":\"per_1\",\"reply\":\"once\"}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let cleared = await waitUntil { !store.isLoading && store.pending.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertFalse(store.hasPending)
        XCTAssertFalse(store.canReply("per_1"))
    }

    @MainActor func testOtherSessionAndUntrackedEventsIgnored() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        let reads = await load.count()
        // Another session's permission event is not this session's fact.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked", data: "{\"sessionID\":\"ses-other\"}"
        )))
        // An untracked family for the active session belongs elsewhere.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status", data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"busy\"}}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, reads)
    }

    @MainActor func testUnattributablePermissionEventRereadsRetainingFacts() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        let reads = await load.count()
        // A recognized permission event with no attributable session cannot
        // be applied. It reconciles by reread, never by guessing.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked", data: "{}"
        )))
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, reads + 1)
    }

    @MainActor func testDuplicateEnvelopesSuppressed() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        let asked = try envelope(
            type: "permission.asked", id: "evt-same",
            data: "{\"sessionID\":\"ses-1\"}"
        )
        store.receive(.event(generation: 1, envelope: asked))
        await load.waitUntilEntered(1)
        // Exact redelivery is a duplicate, not a second invalidation.
        store.receive(.event(generation: 1, envelope: asked))
        for _ in 0..<20 { await Task.yield() }
        let duplicateReads = await load.count()
        XCTAssertEqual(duplicateReads, 2)
        await load.resolve(1, [request(id: "per_1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, 2)
    }

    // MARK: Slow reads, epochs, follow-up

    @MainActor func testEventDuringSlowReadNotOverwrittenWithFollowUp() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "permission.asked", id: "evt-asked",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        // No second request starts while one is in flight.
        for _ in 0..<10 { await Task.yield() }
        let midFlightReads = await load.count()
        XCTAssertEqual(midFlightReads, 1)
        await load.resolve(0, [request(id: "per_1")])
        await load.waitUntilEntered(1)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        await load.resolve(1, [request(id: "per_1"), request(id: "per_2")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.pending.map(\.id), ["per_1", "per_2"])
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, 2)
    }

    @MainActor func testBurstEventsCoalesceSingleFollowUp() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { !store.isLoading }
        XCTAssertTrue(listed)
        for index in 0..<5 {
            store.receive(.event(generation: 1, envelope: try envelope(
                type: "permission.asked", id: "evt-\(index)",
                data: "{\"sessionID\":\"ses-1\"}"
            )))
        }
        // The first event starts the follow-up; the burst coalesces into it.
        // (One event triggers one read; the remaining four arrive mid-flight
        // and converge into exactly one more.)
        await load.waitUntilEntered(1)
        for _ in 0..<20 { await Task.yield() }
        let burstReads = await load.count()
        XCTAssertEqual(burstReads, 2)
        await load.resolve(1, [request(id: "per_1")])
        await load.waitUntilEntered(2)
        await load.resolve(2, [request(id: "per_1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, 3)
    }

    @MainActor func testOverlappingRefreshNewestWins() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        store.refresh()
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_new")])
        let listed = await waitUntil { store.pending.map(\.id) == ["per_new"] }
        XCTAssertTrue(listed)
        // The superseded reply publishes nothing.
        await load.resolve(0, [request(id: "per_stale")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.pending.map(\.id), ["per_new"])
    }

    @MainActor func testConnectedTriggersRereadWithoutWatermark() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        // The readiness marker carries no ordering proof, so it invalidates
        // rather than confirms: exactly one scoped reread follows.
        store.receive(.connected(generation: 1))
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let readCount = await load.count()
        XCTAssertEqual(readCount, 2)
    }

    // MARK: Failure honesty

    @MainActor func testStreamFailureRetainsFactsAndDisablesApproval() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        store.receive(.failed(generation: 1))
        // Facts are retained but the display refuses approval from a dead
        // stream, and never claims settlement.
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        XCTAssertTrue(store.isStale)
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        let replyCalls = await reply.count()
        XCTAssertEqual(replyCalls, 0)
    }

    @MainActor func testReadFailureRetainsFactsMarkedStaleThenRecovers() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        store.refresh()
        await load.waitUntilEntered(1)
        await load.reject(1)
        let stale = await waitUntil { store.isStale }
        XCTAssertTrue(stale)
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        XCTAssertFalse(store.canReply("per_1"))
        store.refresh()
        await load.waitUntilEntered(2)
        await load.resolve(2, [request(id: "per_1"), request(id: "per_2")])
        let recovered = await waitUntil { !store.isStale && store.pending.map(\.id) == ["per_1", "per_2"] }
        XCTAssertTrue(recovered)
    }

    // MARK: Reply matrix

    @MainActor func testReplyOnceAcceptedRereadsWithoutSettlementClaim() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.accepted)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        let sent = await waitUntil { await reply.count() == 1 }
        XCTAssertTrue(sent)
        let calls = await reply.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.session, SessionID(rawValue: "ses-1"))
        XCTAssertEqual(calls.first?.requestID, "per_1")
        XCTAssertEqual(calls.first?.choice, .once)
        // Acceptance is not settlement proof: the entry stays until the
        // confirming read reconciles the authoritative list.
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let cleared = await waitUntil { !store.isLoading && store.pending.isEmpty }
        XCTAssertTrue(cleared)
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.attentionReason)
        XCTAssertFalse(store.hasUnknownReply("per_1"))
        let finalCalls = await reply.count()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testReplyRejectChoiceForwarded() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.accepted)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .reject)
        let sent = await waitUntil { await reply.count() == 1 }
        XCTAssertTrue(sent)
        let calls = await reply.calls()
        XCTAssertEqual(calls.first?.choice, .reject)
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let cleared = await waitUntil { store.pending.isEmpty }
        XCTAssertTrue(cleared)
    }

    @MainActor func testReplyNotFoundIsHonestMissingNotSuccess() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.notFound)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        let settled = await waitUntil { await reply.count() == 1 && store.lastError != nil }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.lastError, "The request is no longer pending.")
        // The 404 never removes locally and never claims success: the entry
        // stays until the reread (which any reply triggers) reconciles it.
        XCTAssertEqual(store.pending.map(\.id), ["per_1"])
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let cleared = await waitUntil { !store.isLoading && store.pending.isEmpty }
        XCTAssertTrue(cleared)
        // The honest-missing notice survives its own reread.
        XCTAssertEqual(store.lastError, "The request is no longer pending.")
        let finalCalls = await reply.count()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testReplyRejectedReportsAndAllowsExplicitRetry() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.rejected)
        await reply.enqueue(.accepted)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        let rejected = await waitUntil { await reply.count() == 1 && store.lastError != nil }
        XCTAssertTrue(rejected)
        XCTAssertEqual(store.lastError, "The reply was rejected.")
        await load.waitUntilEntered(1)
        await load.resolve(1, [request(id: "per_1")])
        // A declared rejection returns to idle for the still-pending id: the
        // user may retry explicitly with one new POST.
        let ready = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(ready)
        store.reply(requestID: "per_1", decision: .once)
        let retried = await waitUntil { await reply.count() == 2 }
        XCTAssertTrue(retried)
    }

    @MainActor func testReplyUnknownRetainsAmbiguityEvenWhenAbsent() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.unknown)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        let lost = await waitUntil { await reply.count() == 1 && store.hasUnknownReply("per_1") }
        XCTAssertTrue(lost)
        XCTAssertFalse(store.canReply("per_1"))
        XCTAssertNotNil(store.attentionReason)
        // While the outcome is uncertain, further taps never re-POST.
        await load.waitUntilEntered(1)
        store.reply(requestID: "per_1", decision: .once)
        store.reply(requestID: "per_1", decision: .reject)
        let suppressedCalls = await reply.count()
        XCTAssertEqual(suppressedCalls, 1)
        // The reread no longer lists the id, but absence is not success: the
        // ambiguity is retained, not auto-retried, not claimed settled.
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(store.hasUnknownReply("per_1"))
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        for _ in 0..<20 { await Task.yield() }
        let finalCalls = await reply.count()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testDuplicateReplyWhileInFlightSuppressed() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.holdNext()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        let sent = await waitUntil { await reply.count() == 1 }
        XCTAssertTrue(sent)
        XCTAssertTrue(store.isReplying("per_1"))
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        store.reply(requestID: "per_1", decision: .reject)
        for _ in 0..<20 { await Task.yield() }
        let suppressedCalls = await reply.count()
        XCTAssertEqual(suppressedCalls, 1)
        await reply.release(.accepted)
        let accepted = await waitUntil { !store.isReplying("per_1") }
        XCTAssertTrue(accepted)
        await load.waitUntilEntered(1)
        // The server has not settled yet: the still-listed id reconciles back
        // to tappable without inventing a settlement claim.
        await load.resolve(1, [request(id: "per_1")])
        let ready = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(ready)
        let finalCalls = await reply.count()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testAcceptedAwaitingReadSuppressesTaps() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        await reply.enqueue(.accepted)
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.canReply("per_1") }
        XCTAssertTrue(listed)
        store.reply(requestID: "per_1", decision: .once)
        // The accepted reply awaits its confirming read: further taps stay
        // suppressed even though no transport is in flight.
        let awaiting = await waitUntil { await reply.count() == 1 && !store.isReplying("per_1") }
        XCTAssertTrue(awaiting)
        XCTAssertFalse(store.canReply("per_1"))
        store.reply(requestID: "per_1", decision: .once)
        for _ in 0..<20 { await Task.yield() }
        let suppressedCalls = await reply.count()
        XCTAssertEqual(suppressedCalls, 1)
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let cleared = await waitUntil { store.pending.isEmpty }
        XCTAssertTrue(cleared)
    }

    @MainActor func testReplyForUnknownIDIsNoOp() async throws {
        let load = ScriptedPermissionLoad()
        let reply = ScriptedPermissionReply()
        let store = makeStore(load: load, reply: reply)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [request(id: "per_1")])
        let listed = await waitUntil { store.hasPending }
        XCTAssertTrue(listed)
        // An id outside the authoritative list can never be answered.
        store.reply(requestID: "per_missing", decision: .once)
        for _ in 0..<20 { await Task.yield() }
        let replyCalls = await reply.count()
        XCTAssertEqual(replyCalls, 0)
        XCTAssertNil(store.lastError)
    }
}

// MARK: - Test doubles

private final class PermissionSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: SessionID?
    var current: SessionID? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(current: SessionID? = SessionID(rawValue: "ses-1")) { boxed = current }
}

private final class PermissionConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: UInt64?
    var generation: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(generation: UInt64? = 1) { boxed = generation }
}

private actor ScriptedPermissionLoad {
    private var entered: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<[PermissionRequest], Error>] = [:]
    private var started = 0
    private var sessions: [SessionID] = []

    func run(_ session: SessionID) async throws -> [PermissionRequest] {
        let index = started
        started += 1
        sessions.append(session)
        entered.insert(index)
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }

    @discardableResult
    func waitUntilEntered(_ index: Int, attempts: Int = 20_000) async -> Bool {
        var remaining = attempts
        while !entered.contains(index), remaining > 0 {
            remaining -= 1
            await Task.yield()
        }
        return entered.contains(index)
    }

    func resolve(_ index: Int, _ members: [PermissionRequest]) {
        waiters.removeValue(forKey: index)?.resume(returning: members)
    }

    func reject(_ index: Int) {
        struct ReadFailed: Error {}
        waiters.removeValue(forKey: index)?.resume(throwing: ReadFailed())
    }

    func count() -> Int { started }

    func requestedSessions() -> [SessionID] { sessions }
}

private actor ScriptedPermissionReply {
    struct Call: Sendable {
        let session: SessionID
        let requestID: String
        let choice: PermissionChoice
    }

    private var queued: [PermissionReplyOutcome] = []
    private var callsMade: [Call] = []
    private var holdArmed = false
    private var held: CheckedContinuation<PermissionReplyOutcome, Never>?

    func enqueue(_ outcome: PermissionReplyOutcome) { queued.append(outcome) }

    func holdNext() { holdArmed = true }

    func call(_ session: SessionID, _ requestID: String, _ choice: PermissionChoice) async -> PermissionReplyOutcome {
        callsMade.append(Call(session: session, requestID: requestID, choice: choice))
        if holdArmed {
            holdArmed = false
            return await withCheckedContinuation { held = $0 }
        }
        guard !queued.isEmpty else { return .unknown }
        return queued.removeFirst()
    }

    func release(_ outcome: PermissionReplyOutcome) {
        held?.resume(returning: outcome)
        held = nil
    }

    func count() -> Int { callsMade.count }

    func calls() -> [Call] { callsMade }
}
