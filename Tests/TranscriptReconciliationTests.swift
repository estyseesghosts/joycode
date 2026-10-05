import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript live reconciliation tests (R08)
//
// Deterministic tests over a controlled `load` and hand-delivered fanout
// signals (no network). They pin the invalidate-and-resync model: events never
// merge into records, never cancel an in-flight fetch, coalesce into one
// follow-up, and only removals leave tombstones. See
// docs/plan/r08-live-reconciliation-2026-10-05.md.

@MainActor
final class TranscriptReconciliationTests: XCTestCase {
    // MARK: Fixtures

    private func user(_ id: String) -> TranscriptMessage {
        .user(TranscriptTextMessage(id: id, created: 1, text: id))
    }

    /// Server order is newest first; the store reverses once for display.
    private func page(_ ids: String...) -> TranscriptPage {
        TranscriptPage(messages: ids.map(user), cursor: TranscriptCursor(previous: nil, next: nil))
    }

    private func ids(_ store: TranscriptStore) -> [String?] {
        store.messages.map(\.messageID)
    }

    private func event(_ type: String, session: String? = "ses-1", extra: String = "", generation: UInt64 = 1) throws -> ConnectionEventSignal {
        var fields: [String] = []
        if let session { fields.append("\"sessionID\":\"\(session)\"") }
        if !extra.isEmpty { fields.append(extra) }
        let json = "{\"id\":\"evt-\(type)\",\"type\":\"\(type)\",\"created\":1,\"data\":{\(fields.joined(separator: ","))}}"
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
        return .event(generation: generation, envelope: envelope)
    }

    private struct Harness {
        let store: TranscriptStore
        let load: ReconLoad
        let session: ReconSessionBox
        let connection: ReconConnectionBox
    }

    private func harness(awaitsEventStream: Bool = true) -> Harness {
        let load = ReconLoad()
        let session = ReconSessionBox(SessionID(rawValue: "ses-1"))
        let connection = ReconConnectionBox(1)
        let store = TranscriptStore(
            activeSessionID: { session.current },
            connectionGeneration: { connection.generation },
            awaitsEventStream: awaitsEventStream,
            resyncDelay: .zero,
            load: { id, query in try await load.run(session: id, query: query) }
        )
        return Harness(store: store, load: load, session: session, connection: connection)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Ready stream and a published first snapshot.
    private func liveHarness(_ ids: String...) async throws -> Harness {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let entered = await h.load.waitForCalls(1)
        XCTAssertTrue(entered)
        await h.load.resolve(0, TranscriptPage(messages: ids.map(user), cursor: TranscriptCursor(previous: nil, next: nil)))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        return h
    }

    // MARK: Readiness gating

    func testNoSnapshotBeforeReadinessThenHydratesAfterConnected() async throws {
        let h = harness()
        h.store.contextChanged()
        await settle()
        let none = await h.load.callCount()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(h.store.synchronization, .awaitingStream)

        h.store.receive(.connected(generation: 1))
        let started = await h.load.waitForCalls(1)
        XCTAssertTrue(started)
        XCTAssertEqual(h.store.synchronization, .hydrating)
        await h.load.resolve(0, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testReadinessInvalidatesAnEarlierExplicitSnapshot() async throws {
        let h = harness()
        h.store.refresh()
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)
        await h.load.resolve(0, page("m1"))
        let snapshot = await waitUntil { h.store.synchronization == .snapshotOnly }
        XCTAssertTrue(snapshot)

        h.store.receive(.connected(generation: 1))
        let second = await h.load.waitForCalls(2)
        XCTAssertTrue(second)
        XCTAssertEqual(h.store.synchronization, .resyncing)
        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testStoreWithoutEventStreamStaysSnapshotOnly() async throws {
        let h = harness(awaitsEventStream: false)
        h.store.refresh()
        let started = await h.load.waitForCalls(1)
        XCTAssertTrue(started)
        await h.load.resolve(0, page("m1"))
        let shown = await waitUntil { h.store.messages.count == 1 }
        XCTAssertTrue(shown)
        XCTAssertEqual(h.store.synchronization, .snapshotOnly)
    }

    // MARK: Invalidation, coalescing, and ordering

    func testEventDuringFetchPublishesReplyAsResyncingThenFollowsUp() async throws {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)

        h.store.receive(try event("session.tool.success"))
        // The in-flight fetch is not cancelled or duplicated by the event.
        await settle()
        let stillOne = await h.load.callCount()
        XCTAssertEqual(stillOne, 1)

        await h.load.resolve(0, page("m1"))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertEqual(h.store.synchronization, .resyncing)

        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testBurstOfDuplicateEventsCoalescesIntoOneFollowUp() async throws {
        let h = try await liveHarness("m1")
        for _ in 0..<12 { h.store.receive(try event("session.step.ended")) }
        XCTAssertEqual(h.store.synchronization, .resyncing)
        let started = await h.load.waitForCalls(2)
        XCTAssertTrue(started)
        await settle()
        let total = await h.load.callCount()
        XCTAssertEqual(total, 2)
        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
        let settled = await h.load.callCount()
        XCTAssertEqual(settled, 2)
    }

    func testReplyForSupersededRequestNeverOverwritesNewerSnapshot() async throws {
        let h = try await liveHarness("m1")
        h.store.refresh()
        let second = await h.load.waitForCalls(2)
        XCTAssertTrue(second)
        h.store.refresh()
        let third = await h.load.waitForCalls(3)
        XCTAssertTrue(third)
        await h.load.resolve(2, page("m3", "m2", "m1"))
        let newest = await waitUntil { self.ids(h.store) == ["m1", "m2", "m3"] }
        XCTAssertTrue(newest)
        await h.load.resolve(1, page("old"))
        await settle()
        XCTAssertEqual(ids(h.store), ["m1", "m2", "m3"])
    }

    func testEphemeralDeltasAndStatusEventsDoNotRefresh() async throws {
        let h = try await liveHarness("m1")
        for type in ["session.text.delta", "session.reasoning.delta", "session.tool.progress", "session.status", "session.usage.updated"] {
            h.store.receive(try event(type))
        }
        await settle()
        let count = await h.load.callCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testEventsForOtherSessionsAndGenerationsAreIgnored() async throws {
        let h = try await liveHarness("m1")
        h.store.receive(try event("session.tool.success", session: "ses-other"))
        h.store.receive(try event("session.deleted", session: "ses-other"))
        h.store.receive(try event("session.revert.committed", session: "ses-other", extra: "\"to\":\"m1\""))
        h.store.receive(try event("session.tool.success", generation: 7))
        h.store.receive(.failed(generation: 7))
        await settle()
        let count = await h.load.callCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testUnroutableAndUnknownSessionEventsRefreshTheActiveSession() async throws {
        let h = try await liveHarness("m1")
        h.store.receive(try event("session.tool.success", session: nil))
        let first = await h.load.waitForCalls(2)
        XCTAssertTrue(first)
        await h.load.resolve(1, page("m1"))
        let settledOnce = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(settledOnce)

        h.store.receive(try event("session.future.thing"))
        let second = await h.load.waitForCalls(3)
        XCTAssertTrue(second)
        await h.load.resolve(2, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
    }

    // MARK: Removals

    func testRevertCommittedTruncatesDisplayAtBoundaryThenResyncs() async throws {
        let h = try await liveHarness("m4", "m3", "m2", "m1")
        XCTAssertEqual(ids(h.store), ["m1", "m2", "m3", "m4"])
        h.store.receive(try event("session.revert.committed", extra: "\"to\":\"m3\""))
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
        XCTAssertEqual(h.store.synchronization, .resyncing)

        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testSnapshotThatBeganBeforeRemovalIsDiscardedAndRefetched() async throws {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)

        h.store.receive(try event("session.revert.committed", extra: "\"to\":\"m3\""))
        await h.load.resolve(0, page("m4", "m3", "m2", "m1"))
        let refetch = await h.load.waitForCalls(2)
        XCTAssertTrue(refetch)
        // The pre-removal reply must never appear.
        XCTAssertTrue(h.store.messages.isEmpty)
        XCTAssertNotEqual(h.store.synchronization, .live)

        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testLaterSnapshotsAreFilteredByTombstones() async throws {
        let h = try await liveHarness("m4", "m3", "m2", "m1")
        h.store.receive(try event("session.revert.committed", extra: "\"to\":\"m3\""))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        // A lagging read that still contains removed records cannot revive them.
        await h.load.resolve(1, page("m4", "m3", "m2", "m1"))
        let settled = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(settled)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testRevertBoundaryNotDisplayedKeepsDisplayButIsNotLive() async throws {
        let h = try await liveHarness("m2", "m1")
        h.store.receive(try event("session.revert.committed", extra: "\"to\":\"m9\""))
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
        XCTAssertEqual(h.store.synchronization, .resyncing)
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        await h.load.resolve(1, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1"])
    }

    func testSessionDeletedClearsBlocksHydrationAndResetsOnOtherSession() async throws {
        let h = try await liveHarness("m1")
        h.store.receive(try event("session.deleted"))
        XCTAssertTrue(h.store.messages.isEmpty)
        XCTAssertEqual(h.store.synchronization, .sessionRemoved)
        XCTAssertEqual(h.store.unavailableMessage, "This session was deleted.")

        h.store.refresh()
        h.store.receive(try event("session.tool.success"))
        h.store.receive(.connected(generation: 1))
        await settle()
        let blocked = await h.load.callCount()
        XCTAssertEqual(blocked, 1)
        XCTAssertEqual(h.store.synchronization, .sessionRemoved)

        h.session.current = SessionID(rawValue: "ses-2")
        h.store.contextChanged()
        let other = await h.load.waitForCalls(2)
        XCTAssertTrue(other)
        let sessions = await h.load.sessions()
        XCTAssertEqual(sessions.last, SessionID(rawValue: "ses-2"))
        XCTAssertNil(h.store.unavailableMessage)
        await h.load.resolve(1, page("x1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)

        // The deleted session stays blocked on this connection.
        h.session.current = SessionID(rawValue: "ses-1")
        h.store.contextChanged()
        await settle()
        let after = await h.load.callCount()
        XCTAssertEqual(after, 2)
        XCTAssertEqual(h.store.synchronization, .sessionRemoved)
    }

    // MARK: Context replacement

    func testSessionReplacementClearsDisplayAndIgnoresOldReply() async throws {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)

        h.session.current = SessionID(rawValue: "ses-2")
        h.store.contextChanged()
        let second = await h.load.waitForCalls(2)
        XCTAssertTrue(second)
        await h.load.resolve(0, page("old"))
        await settle()
        XCTAssertTrue(h.store.messages.isEmpty)
        await h.load.resolve(1, page("new"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["new"])
        XCTAssertEqual(h.store.publishedSessionID, SessionID(rawValue: "ses-2"))
    }

    func testConnectionReplacementWaitsForNewReadinessAndIgnoresOldSignals() async throws {
        let h = try await liveHarness("m1")
        h.connection.generation = 2
        h.store.contextChanged()
        XCTAssertTrue(h.store.messages.isEmpty)
        XCTAssertEqual(h.store.synchronization, .awaitingStream)

        // Late signals from the replaced generation are ignored.
        h.store.receive(.connected(generation: 1))
        h.store.receive(try event("session.tool.success", generation: 1))
        await settle()
        let none = await h.load.callCount()
        XCTAssertEqual(none, 1)

        h.store.receive(.connected(generation: 2))
        let started = await h.load.waitForCalls(2)
        XCTAssertTrue(started)
        await h.load.resolve(1, page("g2"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["g2"])
        XCTAssertEqual(h.store.publishedConnection, 2)
    }

    // MARK: Failure

    func testStreamFailureMarksStreamLostWithoutClearingRecords() async throws {
        let h = try await liveHarness("m1")
        h.store.receive(.failed(generation: 1))
        XCTAssertEqual(h.store.synchronization, .streamLost)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertFalse(h.store.messages.isEmpty)
    }

    func testFailedFollowUpKeepsRecordsAndReportsRefreshFailure() async throws {
        let h = try await liveHarness("m1")
        h.store.receive(try event("session.tool.success"))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        await h.load.fail(1, TranscriptAPIError.requestFailed)
        let failed = await waitUntil { h.store.synchronization == .refreshFailed }
        XCTAssertTrue(failed)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertTrue(h.store.isStale)
    }

    // MARK: Composition seam

    func testBoundStoreReceivesFanoutSignalsIncludingLateReplayedReadiness() async throws {
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        fanout.deliver(.connected(generation: 1))

        let h = harness()
        h.store.contextChanged()
        // Late binding still observes readiness through the phase replay.
        ConversationComposition.bindTranscriptEvents(h.store, fanout: fanout)
        let started = await h.load.waitForCalls(1)
        XCTAssertTrue(started)
        await h.load.resolve(0, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)

        fanout.deliver(try event("session.tool.success"))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        await h.load.resolve(1, page("m2", "m1"))
        let updated = await waitUntil { self.ids(h.store) == ["m1", "m2"] }
        XCTAssertTrue(updated)

        fanout.deliver(.failed(generation: 1))
        XCTAssertEqual(h.store.synchronization, .streamLost)
    }
}

// MARK: - Test doubles

private final class ReconSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: SessionID?
    var current: SessionID? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(_ current: SessionID?) { boxed = current }
}

private final class ReconConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: UInt64?
    var generation: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(_ generation: UInt64?) { boxed = generation }
}

/// Suspends every call until the test resolves or fails it by call index.
private actor ReconLoad {
    private var sessionLog: [SessionID] = []
    private var waiters: [Int: CheckedContinuation<TranscriptPage, Error>] = [:]

    func run(session: SessionID, query: TranscriptQuery) async throws -> TranscriptPage {
        let index = sessionLog.count
        sessionLog.append(session)
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }

    func callCount() -> Int { sessionLog.count }

    func sessions() -> [SessionID] { sessionLog }

    func waitForCalls(_ count: Int) async -> Bool {
        for _ in 0..<300 {
            if sessionLog.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sessionLog.count >= count
    }

    func resolve(_ index: Int, _ page: TranscriptPage) {
        waiters.removeValue(forKey: index)?.resume(returning: page)
    }

    func fail(_ index: Int, _ error: Error) {
        waiters.removeValue(forKey: index)?.resume(throwing: error)
    }
}
