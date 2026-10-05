import Foundation
import XCTest
@testable import Joycode

// MARK: - Execution status store tests (R09, offline)
//
// Deterministic tests over controlled `loadActive` / `interrupt` closures and
// synthetic fanout signals: running-membership reads with provenance,
// event-reported outcomes, durable/ephemeral duplicate suppression, slow-read
// epochs with follow-up, session/generation replacement, stream failure (never
// claims stopped), and the full interrupt matrix (accepted / busy / unknown /
// false / lost reply with no re-POST). No live, service, or provider use.

final class ExecutionStatusStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor private func waitUntil(_ condition: @escaping @MainActor @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func envelope(
        type: String,
        id: String = "evt-1",
        data: String,
        seq: Int? = nil,
        aggregate: String = "ses-1"
    ) throws -> EventEnvelope {
        let durable = seq.map { ",\"durable\":{\"aggregateID\":\"\(aggregate)\",\"seq\":\($0),\"version\":1}" } ?? ""
        let json = "{\"id\":\"\(id)\",\"type\":\"\(type)\",\"created\":1,\"data\":\(data)\(durable)}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    @MainActor private func makeStore(
        session: SessionBox? = nil,
        connection: ConnectionBox? = nil,
        load: ScriptedActiveLoad,
        interrupt: ScriptedInterrupt
    ) -> ExecutionStatusStore {
        let sessionBox = session ?? SessionBox(current: SessionID(rawValue: "ses-1"))
        let connectionBox = connection ?? ConnectionBox(generation: 1)
        return ExecutionStatusStore(
            activeSessionID: { sessionBox.current },
            connectionGeneration: { connectionBox.generation },
            loadActive: { try await load.run() },
            interrupt: { id in await interrupt.call(id) }
        )
    }

    // MARK: Membership reads and provenance

    @MainActor func testActiveMapMembershipShowsWorkingWithReadProvenance() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        XCTAssertEqual(store.statusLabel, "Working")
        XCTAssertTrue(store.canInterrupt)
        XCTAssertEqual(store.isActive, true)
        XCTAssertFalse(store.isStale)
        XCTAssertFalse(store.confirmedStopped)
        let provenance = try XCTUnwrap(store.activeProvenance)
        XCTAssertEqual(provenance.session, SessionID(rawValue: "ses-1"))
        XCTAssertEqual(provenance.generation, 1)
        XCTAssertEqual(provenance.source, .activeRead(epoch: 1))
    }

    @MainActor func testInactiveReadWithoutTerminalShowsIdleOnly() async {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        XCTAssertEqual(store.statusLabel, "Idle")
        XCTAssertEqual(store.statusReason, "")
        XCTAssertFalse(store.canInterrupt)
        XCTAssertTrue(store.confirmedStopped)
        XCTAssertNil(store.lastOutcome)
    }

    @MainActor func testNilSessionShowsNoSessionWithoutTransport() async {
        let sessionBox = SessionBox(current: nil)
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(session: sessionBox, load: load, interrupt: interrupt)
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        // No selection means no execution to report on: a truthful no-session
        // presentation (never an idle claim), no transport, interrupt disabled.
        let startedReads = await load.count()
        XCTAssertEqual(startedReads, 0)
        XCTAssertEqual(store.phase, .noSession)
        XCTAssertEqual(store.statusLabel, "No session")
        XCTAssertEqual(store.statusReason, "")
        XCTAssertFalse(store.canInterrupt)
        store.interrupt()
        let interruptCalls = await interrupt.count()
        XCTAssertEqual(interruptCalls, 0)
    }

    @MainActor func testNilConnectionDisablesTransport() async {
        let connectionBox = ConnectionBox(generation: nil)
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(connection: connectionBox, load: load, interrupt: interrupt)
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        let startedReads = await load.count()
        XCTAssertEqual(startedReads, 0)
        XCTAssertEqual(store.statusReason, "Not connected.")
        XCTAssertFalse(store.canInterrupt)
    }

    // MARK: Event outcomes and confirmation

    @MainActor func testStartedEventShowsWorkingBeforeReadCompletes() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.started",
            id: "evt-start",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        // The in-flight read is never cancelled by the event; the outcome is
        // visible immediately with event provenance.
        XCTAssertEqual(store.lastOutcome, .started)
        XCTAssertEqual(store.phase, .working)
        let provenance = try XCTUnwrap(store.outcomeProvenance)
        XCTAssertEqual(provenance.source, .event(type: "session.execution.started", id: "evt-start"))
        // The read still owns membership: an empty list reconciles the bare
        // start to idle (a read cannot prove the start caused anything else).
        await load.resolve(0, [])
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.isActive, false)
        XCTAssertEqual(store.phase, .idle)
    }

    @MainActor func testSucceededEventProvisionalThenConfirmedByReread() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.succeeded",
            id: "evt-done",
            data: "{\"sessionID\":\"ses-1\"}",
            seq: 1
        )))
        // Terminal report, but the active list still owns cleanup: the last
        // outcome is recorded without stop confirmation, the phase stays
        // working, and a scoped reread is issued to confirm.
        XCTAssertEqual(store.lastOutcome, .succeeded)
        XCTAssertEqual(store.phase, .working)
        XCTAssertFalse(store.confirmedStopped)
        XCTAssertEqual(store.statusReason, "Last reported outcome: succeeded. Cleanup may still be running.")
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let confirmed = await waitUntil { store.confirmedStopped && store.phase == .completed }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.statusReason, "")
        XCTAssertFalse(store.canInterrupt)
    }

    @MainActor func testFailedEventSurfacesErrorAndAttention() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        // The terminal report arrives before any read: last outcome without
        // stop confirmation, plus the scoped confirming read (index 0: no
        // refresh ran before the event).
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.failed",
            id: "evt-fail",
            data: "{\"sessionID\":\"ses-1\",\"error\":{\"type\":\"ToolError\",\"message\":\"boom\"}}",
            seq: 1
        )))
        XCTAssertEqual(store.lastOutcome, .failed(SessionError.Error(
            type: "ToolError",
            message: "boom",
            raw: .object(["type": .string("ToolError"), "message": .string("boom")])
        )))
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.statusLabel, "Failed")
        XCTAssertEqual(store.statusReason, "boom")
        XCTAssertEqual(store.attention, ExecutionAttention(needsAttention: true, reason: "boom"))
        // The follow-up read is scoped: empty membership confirms the stop.
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let confirmed = await waitUntil { store.confirmedStopped }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.phase, .failed)
    }

    @MainActor func testInterruptedReasonsParseWithUnknownFallback() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        for wire in ["user", "shutdown", "superseded", "inactivity", "explode"] {
            store.receive(.event(generation: 1, envelope: try envelope(
                type: "session.execution.interrupted",
                id: "evt-\(wire)",
                data: "{\"sessionID\":\"ses-1\",\"reason\":\"\(wire)\"}",
                seq: 1,
                aggregate: "agg-\(wire)"
            )))
        }
        // Each aggregate admits its own seq; the last delivery (unrecognized
        // reason) falls back to unknown without failing the event.
        XCTAssertEqual(store.lastOutcome, .interrupted(.unknown))
        XCTAssertEqual(store.phase, .interrupted(.unknown))
        XCTAssertEqual(store.statusLabel, "Interrupted")
        XCTAssertTrue(store.statusReason.hasPrefix("Interrupted."))
    }

    @MainActor func testInterruptReasonUserText() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.interrupted",
            data: "{\"sessionID\":\"ses-1\",\"reason\":\"user\"}"
        )))
        XCTAssertEqual(store.phase, .interrupted(.user))
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let confirmed = await waitUntil { store.confirmedStopped }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.statusReason, "Interrupted by user.")
    }

    // MARK: Liveness hints never prove membership or blocked

    @MainActor func testStatusBusyAndRetryShowWorkingNeverBlocked() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-busy",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"busy\"}}"
        )))
        XCTAssertEqual(store.liveness, .busy)
        XCTAssertEqual(store.phase, .working)
        XCTAssertNotEqual(store.phase, .blocked)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-retry",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"retry\",\"attempt\":2,\"message\":\"waiting\",\"next\":30}}"
        )))
        XCTAssertEqual(store.liveness, .retry(ExecutionRetryDetail(attempt: 2, message: "waiting", next: 30)))
        // Retry detail is surfaced as a reason, never as R10/R11 blocked.
        XCTAssertEqual(store.phase, .working)
        XCTAssertNotEqual(store.phase, .blocked)
        XCTAssertEqual(store.statusReason, "waiting")
        // Negative attempt is malformed: ignored, prior liveness retained.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-retry-bad",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"retry\",\"attempt\":-1,\"message\":\"x\",\"next\":0}}"
        )))
        XCTAssertEqual(store.liveness, .retry(ExecutionRetryDetail(attempt: 2, message: "waiting", next: 30)))
        await load.resolve(0, [])
        // The events arrived mid-flight, so exactly one follow-up read runs.
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let readCount = await load.count()
        XCTAssertEqual(readCount, 2)
    }

    @MainActor func testDeprecatedIdleEventShowsIdleHint() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.idle",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        XCTAssertEqual(store.liveness, .idle)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
    }

    @MainActor func testRetryWithStructuredActionObjectIsAccepted() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        // The pinned `action` is an optional structured object, not a string.
        // It must not reject an otherwise valid retry.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-retry-action",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"retry\",\"attempt\":1,\"message\":\"rate limited\",\"next\":5,\"action\":{\"reason\":\"rate_limit\",\"provider\":\"anthropic\",\"title\":\"Rate limited\",\"message\":\"Try later\",\"label\":\"Retry\"}}}"
        )))
        XCTAssertEqual(store.liveness, .retry(ExecutionRetryDetail(attempt: 1, message: "rate limited", next: 5)))
        XCTAssertEqual(store.phase, .working)
        XCTAssertEqual(store.statusReason, "rate limited")
        await load.resolve(0, [])
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
    }

    @MainActor func testMalformedStatusRetainsFactsButReconcilesWithoutStopping() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-busy",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"busy\"}}"
        )))
        XCTAssertEqual(store.liveness, .busy)
        // A malformed status (negative attempt) must not coerce, must not claim
        // stopped, and must not silently retain the stale hint without
        // reconciling: prior liveness is kept but a scoped reread follows.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.status",
            id: "evt-malformed",
            data: "{\"sessionID\":\"ses-1\",\"status\":{\"type\":\"retry\",\"attempt\":-1,\"message\":\"x\",\"next\":0}}"
        )))
        XCTAssertEqual(store.liveness, .busy)
        XCTAssertFalse(store.confirmedStopped)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        await load.waitUntilEntered(1)
        XCTAssertEqual(store.isActive, true)
        XCTAssertFalse(store.confirmedStopped)
        XCTAssertEqual(store.phase, .working)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let reads = await load.count()
        XCTAssertEqual(reads, 2)
    }

    @MainActor func testMalformedFailedErrorUsesSafeFallbackWithoutClaimingStop() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        // A failed event whose error payload is not the pinned object still
        // records a terminal report with a safe message; it never claims stopped
        // (only a fresh inactive read may).
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.failed",
            id: "evt-fail-bad",
            data: "{\"sessionID\":\"ses-1\",\"error\":\"exploded\"}",
            seq: 1
        )))
        XCTAssertEqual(store.lastOutcome, .failed(SessionError.Error(
            type: nil, message: "exploded", raw: .string("exploded")
        )))
        XCTAssertEqual(store.statusReason, "exploded")
        XCTAssertFalse(store.confirmedStopped)
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let confirmed = await waitUntil { store.confirmedStopped }
        XCTAssertTrue(confirmed)
    }

    // MARK: Stale and duplicate suppression

    @MainActor func testStaleDurableReplaySuppressedWithinAggregate() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.succeeded", id: "evt-5",
            data: "{\"sessionID\":\"ses-1\"}", seq: 5
        )))
        await load.waitUntilEntered(1)
        // The active list still owns cleanup: the event never clears the
        // read's membership fact, and the phase stays working.
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let cleanup = await waitUntil { !store.isLoading && store.isActive == true }
        XCTAssertTrue(cleanup)
        XCTAssertEqual(store.lastOutcome, .succeeded)
        XCTAssertEqual(store.phase, .working)
        XCTAssertTrue(store.statusReason.contains("Cleanup may still be running."))
        // Same-seq replay and older seq in the same aggregate are suppressed:
        // no further transport, no fact change.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.succeeded", id: "evt-5-dup",
            data: "{\"sessionID\":\"ses-1\"}", seq: 5
        )))
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.succeeded", id: "evt-3",
            data: "{\"sessionID\":\"ses-1\"}", seq: 3
        )))
        for _ in 0..<20 { await Task.yield() }
        let readCount = await load.count()
        XCTAssertEqual(readCount, 2)
        XCTAssertEqual(store.lastOutcome, .succeeded)
    }

    @MainActor func testEphemeralDuplicateIDsSuppressed() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        let started = try envelope(
            type: "session.execution.started", id: "evt-same",
            data: "{\"sessionID\":\"ses-1\"}"
        )
        store.receive(.event(generation: 1, envelope: started))
        // The slow reply publishes membership without touching the event's
        // outcome fact, then follows up exactly once for the mid-flight event.
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        await load.waitUntilEntered(1)
        XCTAssertEqual(store.isActive, true)
        XCTAssertEqual(store.lastOutcome, .started)
        XCTAssertEqual(store.phase, .working)
        // Exact redelivery of the ephemeral envelope is a duplicate, not a
        // second fact: no additional read follows.
        store.receive(.event(generation: 1, envelope: started))
        for _ in 0..<20 { await Task.yield() }
        let duplicateReads = await load.count()
        XCTAssertEqual(duplicateReads, 2)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, 2)
    }

    // MARK: Slow reads, epochs, and follow-up

    @MainActor func testEventDuringSlowReadNotOverwrittenWithFollowUp() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.started", id: "evt-start",
            data: "{\"sessionID\":\"ses-1\"}"
        )))
        // No second request starts while one is in flight.
        for _ in 0..<10 { await Task.yield() }
        let midFlightReads = await load.count()
        XCTAssertEqual(midFlightReads, 1)
        // The slow reply publishes membership without touching the event's
        // outcome fact, then follows up exactly once.
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        await load.waitUntilEntered(1)
        XCTAssertEqual(store.isActive, true)
        XCTAssertEqual(store.lastOutcome, .started)
        XCTAssertEqual(store.phase, .working)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, 2)
    }

    @MainActor func testOverlappingRefreshNewestWins() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        store.refresh()
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        // The superseded reply publishes nothing.
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.isActive, false)
    }

    // MARK: Session and generation replacement

    @MainActor func testSessionReplacementResetsFacts() async throws {
        let sessionBox = SessionBox(current: SessionID(rawValue: "ses-A"))
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(session: sessionBox, load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-A")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        sessionBox.current = SessionID(rawValue: "ses-B")
        store.contextChanged()
        // The old display clears synchronously; the stale reply cannot publish.
        XCTAssertNil(store.isActive)
        XCTAssertNil(store.lastOutcome)
        await load.waitUntilEntered(1)
        await load.resolve(0, [SessionID(rawValue: "ses-A")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.isActive)
        await load.resolve(1, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        let provenance = try XCTUnwrap(store.activeProvenance)
        XCTAssertEqual(provenance.session, SessionID(rawValue: "ses-B"))
    }

    @MainActor func testConnectionReplacementIgnoresOldGenerationSignals() async throws {
        let connectionBox = ConnectionBox(generation: 1)
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(connection: connectionBox, load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        connectionBox.generation = 2
        store.contextChanged()
        await load.waitUntilEntered(1)
        // Failed-generation signals are ignored: no stale flag, no reset.
        store.receive(.failed(generation: 1))
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.succeeded", data: "{\"sessionID\":\"ses-1\"}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(store.isStale)
        XCTAssertNil(store.lastOutcome)
        // The current generation's failure surfaces unknown/stale, never stopped.
        store.receive(.failed(generation: 2))
        XCTAssertTrue(store.isStale)
        XCTAssertEqual(store.phase, .unknown)
        XCTAssertEqual(store.statusLabel, "Unknown")
        XCTAssertFalse(store.canInterrupt)
        await load.resolve(1, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
    }

    @MainActor func testDuplicateContextChangeIssuesNoTransport() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        store.contextChanged()
        for _ in 0..<20 { await Task.yield() }
        let readCount = await load.count()
        XCTAssertEqual(readCount, 1)
    }

    // MARK: Failure honesty

    @MainActor func testStreamFailureShowsUnknownNeverStopped() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        store.receive(.failed(generation: 1))
        // Membership facts are retained but the display refuses to claim
        // stopped from a dead stream.
        XCTAssertEqual(store.isActive, true)
        XCTAssertTrue(store.isStale)
        XCTAssertEqual(store.phase, .unknown)
        XCTAssertEqual(store.statusReason, "Event stream lost. Status may be stale.")
        XCTAssertFalse(store.canInterrupt)
    }

    @MainActor func testConfirmedStopSurvivesStreamFailure() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        store.receive(.failed(generation: 1))
        // A stop proven before the failure is retained honestly; it was not
        // inferred from the failure.
        XCTAssertEqual(store.phase, .idle)
    }

    @MainActor func testReadFailureRetainsFactsMarkedStale() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.phase == .working }
        XCTAssertTrue(working)
        store.refresh()
        await load.waitUntilEntered(1)
        await load.reject(1)
        let stale = await waitUntil { store.isStale }
        XCTAssertTrue(stale)
        XCTAssertEqual(store.isActive, true)
        XCTAssertEqual(store.phase, .working)
        store.refresh()
        await load.waitUntilEntered(2)
        await load.resolve(2, [])
        let idle = await waitUntil { store.phase == .idle && !store.isStale }
        XCTAssertTrue(idle)
    }

    @MainActor func testConnectedTriggersRereadWithoutWatermark() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        // The readiness marker carries no ordering proof, so it invalidates
        // rather than confirms: exactly one scoped reread follows.
        store.receive(.connected(generation: 1))
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        let readCount = await load.count()
        XCTAssertEqual(readCount, 2)
    }

    @MainActor func testOtherSessionAndNonExecutionEventsIgnored() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        let reads = await load.count()
        // Another session's execution event is not the active session's fact.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.started", data: "{\"sessionID\":\"ses-other\"}"
        )))
        // A non-execution event for the active session belongs to the transcript
        // router, not the execution store.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.tool.success", data: "{\"sessionID\":\"ses-1\"}"
        )))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(store.lastOutcome)
        XCTAssertEqual(store.phase, .idle)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, reads)
    }

    @MainActor func testUnattributableExecutionEventTriggersScopedReread() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [])
        let idle = await waitUntil { store.phase == .idle }
        XCTAssertTrue(idle)
        let reads = await load.count()
        // A recognized execution event with no attributable session cannot be
        // applied. It must reconcile by reread, never guess or silently retain.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.interrupted", data: "{}"
        )))
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertNil(store.lastOutcome)
        XCTAssertEqual(store.phase, .idle)
        let finalReads = await load.count()
        XCTAssertEqual(finalReads, reads + 1)
    }

    // MARK: Interrupt matrix

    @MainActor func testInterruptAcceptedConfirmedByTerminalEvent() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.accepted)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let awaiting = await waitUntil { store.interruptState == .awaitingConfirmation }
        XCTAssertTrue(awaiting)
        XCTAssertEqual(store.phase, .working)
        XCTAssertEqual(store.statusReason, "Interrupt accepted. Awaiting confirmation.")
        // Duplicate requests are suppressed while acceptance is uncertain.
        store.interrupt()
        let interruptCalls = await interrupt.count()
        XCTAssertEqual(interruptCalls, 1)
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.interrupted",
            data: "{\"sessionID\":\"ses-1\",\"reason\":\"user\"}"
        )))
        // The terminal report settles the accepted request at once, but the
        // active list still owns cleanup, so the phase stays working until
        // the scoped reread confirms the stop.
        let requestSettled = await waitUntil { store.interruptState == .idle }
        XCTAssertTrue(requestSettled)
        XCTAssertEqual(store.lastOutcome, .interrupted(.user))
        XCTAssertEqual(store.phase, .working)
        XCTAssertEqual(store.statusLabel, "Working")
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let stopped = await waitUntil { store.confirmedStopped }
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.phase, .interrupted(.user))
        XCTAssertEqual(store.statusReason, "Interrupted by user.")
        let requested = await interrupt.requestedSessions()
        XCTAssertEqual(requested.first, SessionID(rawValue: "ses-1"))
    }

    @MainActor func testInterruptAcceptedWithTerminalDuringRequestResolvesImmediately() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.holdNext()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let sent = await waitUntil { await interrupt.count() == 1 }
        XCTAssertTrue(sent)
        // The terminal report arrives inside the interrupt round-trip, after
        // the request began but before the reply is processed (the production
        // fixture delivers it synchronously from the interrupt closure). The
        // accepted reply then confirms immediately instead of waiting.
        store.receive(.event(generation: 1, envelope: try envelope(
            type: "session.execution.interrupted",
            data: "{\"sessionID\":\"ses-1\",\"reason\":\"shutdown\"}"
        )))
        await interrupt.release(.accepted)
        // The terminal report arrived after the request began, so the
        // accepted reply confirms immediately; the phase still waits on the
        // scoped reread because the active list owns cleanup.
        let settled = await waitUntil { store.interruptState == .idle }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.phase, .working)
        XCTAssertEqual(store.statusReason, "Last reported outcome: interrupted. Cleanup may still be running.")
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let stopped = await waitUntil { store.confirmedStopped }
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.phase, .interrupted(.shutdown))
        XCTAssertEqual(store.statusReason, "Interrupted by server shutdown.")
    }

    @MainActor func testInterruptAcceptedConfirmedByFreshInactiveRead() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.accepted)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let awaiting = await waitUntil { store.interruptState == .awaitingConfirmation }
        XCTAssertTrue(awaiting)
        // No terminal event arrives; the reread begun after the reply shows
        // the session gone. That settles the request without claiming the
        // interruption caused the stop: plain idle, no invented outcome.
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { store.interruptState == .idle && store.phase == .idle }
        XCTAssertTrue(settled)
        XCTAssertNil(store.lastOutcome)
        XCTAssertFalse(store.canInterrupt)
    }

    @MainActor func testInterruptNotInterruptedRereadsWithoutStopClaim() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.notInterrupted)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let settled = await waitUntil { await interrupt.count() == 1 && store.interruptState == .idle }
        XCTAssertTrue(settled)
        // `false` is a valid answer for an idle-nothing-to-stop session; the
        // reread reconciles and the still-listed session keeps working.
        await load.waitUntilEntered(1)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let stillWorking = await waitUntil { !store.isLoading }
        XCTAssertTrue(stillWorking)
        XCTAssertEqual(store.phase, .working)
        XCTAssertTrue(store.canInterrupt)
        XCTAssertNil(store.lastInterruptError)
    }

    @MainActor func testInterruptBusyRereadsAndReports() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.busy)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let settled = await waitUntil { await interrupt.count() == 1 && store.interruptState == .idle }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.lastInterruptError, "Server reported busy.")
        await load.waitUntilEntered(1)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let done = await waitUntil { !store.isLoading }
        XCTAssertTrue(done)
        XCTAssertEqual(store.phase, .working)
    }

    @MainActor func testInterruptUnknownReplyLostSuppressesRepost() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.unknown)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let unknown = await waitUntil { store.interruptState == .unknown }
        XCTAssertTrue(unknown)
        XCTAssertFalse(store.canInterrupt)
        XCTAssertEqual(store.attention.needsAttention, true)
        // While the outcome is uncertain, further taps never re-POST.
        await load.waitUntilEntered(1)
        store.interrupt()
        store.interrupt()
        let suppressedCalls = await interrupt.count()
        XCTAssertEqual(suppressedCalls, 1)
        // Explicit refresh stays allowed and reconciles; the inactive result
        // settles to idle without claiming the lost request caused the stop.
        store.refresh()
        await load.waitUntilEntered(2)
        await load.resolve(1, [])
        await load.resolve(2, [])
        let settled = await waitUntil { store.interruptState == .idle && !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.lastOutcome)
        let finalCalls = await interrupt.count()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor func testInterruptFailedRejectionAllowsExplicitRetry() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.failed)
        await interrupt.enqueue(.accepted)
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let rejected = await waitUntil { await interrupt.count() == 1 && store.interruptState == .idle }
        XCTAssertTrue(rejected)
        XCTAssertEqual(store.lastInterruptError, "Interrupt request failed.")
        // Declared rejections return to idle: the user may retry explicitly.
        await load.waitUntilEntered(1)
        await load.resolve(1, [SessionID(rawValue: "ses-1")])
        let ready = await waitUntil { store.canInterrupt }
        XCTAssertTrue(ready)
        store.interrupt()
        let retried = await waitUntil { await interrupt.count() == 2 }
        XCTAssertTrue(retried)
    }

    @MainActor func testDuplicateInterruptSuppressedWhileRequesting() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.holdNext()
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [SessionID(rawValue: "ses-1")])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let requesting = await waitUntil { store.interruptState == .requesting }
        XCTAssertTrue(requesting)
        store.interrupt()
        store.interrupt()
        for _ in 0..<20 { await Task.yield() }
        let suppressedCalls = await interrupt.count()
        XCTAssertEqual(suppressedCalls, 1)
        await interrupt.release(.accepted)
        let awaiting = await waitUntil { store.interruptState == .awaitingConfirmation }
        XCTAssertTrue(awaiting)
        await load.waitUntilEntered(1)
        await load.resolve(1, [])
        let settled = await waitUntil { store.interruptState == .idle }
        XCTAssertTrue(settled)
    }

    @MainActor func testInterruptTargetsActiveSession() async throws {
        let load = ScriptedActiveLoad()
        let interrupt = ScriptedInterrupt()
        await interrupt.enqueue(.notInterrupted)
        let sessionID = SessionID(rawValue: "ses-1")
        let store = makeStore(load: load, interrupt: interrupt)
        store.refresh()
        await load.waitUntilEntered(0)
        await load.resolve(0, [sessionID])
        let working = await waitUntil { store.canInterrupt }
        XCTAssertTrue(working)
        store.interrupt()
        let done = await waitUntil { await interrupt.count() == 1 }
        XCTAssertTrue(done)
        let requested = await interrupt.requestedSessions()
        XCTAssertEqual(requested, [sessionID])
        await load.waitUntilEntered(1)
        await load.resolve(1, [sessionID])
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
    }
}

// MARK: - Test doubles

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: SessionID?
    var current: SessionID? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(current: SessionID? = SessionID(rawValue: "ses-1")) { boxed = current }
}

private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: UInt64?
    var generation: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(generation: UInt64? = 1) { boxed = generation }
}

private actor ScriptedActiveLoad {
    private var entered: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Set<SessionID>, Error>] = [:]
    private var started = 0

    func run() async throws -> Set<SessionID> {
        let index = started
        started += 1
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

    func resolve(_ index: Int, _ members: Set<SessionID>) {
        waiters.removeValue(forKey: index)?.resume(returning: members)
    }

    func reject(_ index: Int) {
        struct ReadFailed: Error {}
        waiters.removeValue(forKey: index)?.resume(throwing: ReadFailed())
    }

    func count() -> Int { started }
}

private actor ScriptedInterrupt {
    private var queued: [ExecutionInterruptReply] = []
    private var sessions: [SessionID] = []
    private var holdArmed = false
    private var held: CheckedContinuation<ExecutionInterruptReply, Never>?

    func enqueue(_ reply: ExecutionInterruptReply) { queued.append(reply) }

    func holdNext() { holdArmed = true }

    func call(_ session: SessionID) async -> ExecutionInterruptReply {
        sessions.append(session)
        if holdArmed {
            holdArmed = false
            return await withCheckedContinuation { held = $0 }
        }
        guard !queued.isEmpty else { return .unknown }
        return queued.removeFirst()
    }

    func release(_ reply: ExecutionInterruptReply) {
        held?.resume(returning: reply)
        held = nil
    }

    func count() -> Int { sessions.count }

    func requestedSessions() -> [SessionID] { sessions }
}
