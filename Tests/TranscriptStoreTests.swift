import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript snapshot store tests (R07b, snapshot-only)
//
// Deterministic tests over a controlled `load` closure: request params and
// context, both completion orders (newer wins), connection/session replacement
// (stale replies never publish), failure/cancellation retention, repeat
// snapshot replacement without duplicates, and nil-context transport gating.

final class TranscriptStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func userMessage(_ id: String, text: String, created: Double = 1_700_000_000) -> TranscriptMessage {
        .user(TranscriptTextMessage(id: id, created: created, text: text))
    }

    private func assistantMessage(_ id: String, text: String, created: Double = 1_700_000_001) -> TranscriptMessage {
        .assistant(TranscriptAssistantMessage(
            id: id,
            created: created,
            completed: nil,
            agent: "build",
            model: TranscriptModelRef(id: "m", providerID: "p", variant: nil),
            finish: nil,
            error: nil,
            content: [.text(text)]
        ))
    }

    private func page(_ messages: [TranscriptMessage]) -> TranscriptPage {
        TranscriptPage(messages: messages, cursor: TranscriptCursor(previous: nil, next: nil))
    }

    @MainActor private func makeStore(
        session: SessionBox? = nil,
        connection: ConnectionBox? = nil,
        load: @escaping @MainActor @Sendable (SessionID, TranscriptQuery) async throws -> TranscriptPage
    ) -> TranscriptStore {
        let sessionBox = session ?? SessionBox(current: SessionID(rawValue: "ses-1"))
        let connectionBox = connection ?? ConnectionBox(generation: 1)
        return TranscriptStore(
            activeSessionID: { sessionBox.current },
            connectionGeneration: { connectionBox.generation },
            load: load
        )
    }

    // MARK: Request params and context

    @MainActor func testManualRefreshAfterDisconnectClearsOtherContextSnapshot() async {
        let connection = ConnectionBox(generation: 1)
        let expected = page([userMessage("u1", text: "old")])
        let store = makeStore(connection: connection, load: { _, _ in expected })
        store.refresh()
        let loaded = await waitUntil { store.messages.count == 1 }
        XCTAssertTrue(loaded)
        connection.generation = nil
        store.refresh()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.publishedConnection)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.unavailableMessage, "Not connected. History is unavailable.")
    }

    @MainActor func testRefreshRequestsDefaultPageForCurrentSession() async throws {
        let recorder = LoadRecorder()
        let expected = page([userMessage("u1", text: "hi")])
        let store = makeStore(load: { session, query in
            await recorder.record(session: session, query: query)
            return expected
        })
        store.refresh()
        let done = await waitUntil { store.messages.count == 1 }
        XCTAssertTrue(done)
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 1)
        let recorded = try XCTUnwrap(calls.first)
        XCTAssertEqual(recorded.session, SessionID(rawValue: "ses-1"))
        XCTAssertEqual(recorded.query, TranscriptQuery.defaultPage)
        XCTAssertEqual(recorded.query.limit, 50)
        XCTAssertEqual(recorded.query.order, .desc)
        XCTAssertNil(recorded.query.cursor)
        XCTAssertEqual(store.publishedSessionID, SessionID(rawValue: "ses-1"))
        XCTAssertEqual(store.publishedConnection, 1)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isStale)
        XCTAssertNil(store.lastError)
    }

    // MARK: Overlapping refreshes, both completion orders

    @MainActor func testOverlappingRefreshFirstCompletesLastStillLoses() async {
        let script = ScriptedLoad()
        let store = makeStore(load: { session, query in try await script.run(session: session, query: query) })
        store.refresh()
        await script.waitUntilEntered(0)
        store.refresh()
        await script.waitUntilEntered(1)
        let first = page([self.userMessage("first", text: "first")])
        let second = page([self.userMessage("second", text: "second")])
        // Newer request resolves first, older resolves last: older must not win.
        await script.resolve(1, second)
        let secondShown = await waitUntil { store.messages == second.messages }
        XCTAssertTrue(secondShown)
        await script.resolve(0, first)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.messages, second.messages)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testOverlappingRefreshSecondCompletesLastWins() async {
        let script = ScriptedLoad()
        let store = makeStore(load: { session, query in try await script.run(session: session, query: query) })
        store.refresh()
        await script.waitUntilEntered(0)
        store.refresh()
        await script.waitUntilEntered(1)
        let first = page([self.userMessage("first", text: "first")])
        let second = page([self.userMessage("second", text: "second")])
        await script.resolve(0, first)
        for _ in 0..<20 { await Task.yield() }
        // Superseded reply publishes nothing while the newer request is pending.
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.isLoading)
        await script.resolve(1, second)
        let done = await waitUntil { store.messages == second.messages }
        XCTAssertTrue(done)
        XCTAssertFalse(store.isLoading)
    }

    // MARK: Replacement contexts cannot publish stale replies

    @MainActor func testReplacedConnectionStaleReplyCannotPublish() async {
        let sessionBox = SessionBox(current: SessionID(rawValue: "ses-1"))
        let connectionBox = ConnectionBox(generation: 1)
        let script = ScriptedLoad()
        let store = makeStore(session: sessionBox, connection: connectionBox, load: { session, query in
            try await script.run(session: session, query: query)
        })
        store.refresh()
        await script.waitUntilEntered(0)
        connectionBox.generation = 2
        store.contextChanged()
        // Context B clears A display immediately and starts a fresh request.
        XCTAssertTrue(store.messages.isEmpty)
        await script.waitUntilEntered(1)
        await script.resolve(0, page([self.userMessage("stale", text: "stale")]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.messages.isEmpty)
        let fresh = page([self.userMessage("fresh", text: "fresh")])
        await script.resolve(1, fresh)
        let done = await waitUntil { store.messages == fresh.messages }
        XCTAssertTrue(done)
        XCTAssertEqual(store.publishedConnection, 2)
    }

    @MainActor func testReplacedSessionClearsDisplayImmediately() async {
        let sessionBox = SessionBox(current: SessionID(rawValue: "ses-A"))
        let connectionBox = ConnectionBox(generation: 1)
        let recorder = LoadRecorder()
        let store = makeStore(session: sessionBox, connection: connectionBox, load: { session, query in
            await recorder.record(session: session, query: query)
            return self.page([self.userMessage("m-\(session.rawValue)", text: session.rawValue)])
        })
        store.refresh()
        let loaded = await waitUntil { store.messages.count == 1 }
        XCTAssertTrue(loaded)
        sessionBox.current = SessionID(rawValue: "ses-B")
        store.contextChanged()
        // A display is cleared synchronously; B then loads its own snapshot.
        let switched = await waitUntil { store.publishedSessionID == SessionID(rawValue: "ses-B") }
        XCTAssertTrue(switched)
        XCTAssertEqual(store.messages, [userMessage("m-ses-B", text: "ses-B")])
        let sessions = await recorder.sessions()
        XCTAssertEqual(sessions, [SessionID(rawValue: "ses-A"), SessionID(rawValue: "ses-B")])
    }

    @MainActor func testDuplicateContextChangeIssuesNoTransport() async {
        let recorder = LoadRecorder()
        let store = makeStore(load: { session, query in
            await recorder.record(session: session, query: query)
            return self.page([])
        })
        store.refresh()
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        store.contextChanged()
        for _ in 0..<20 { await Task.yield() }
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    // MARK: Failure and cancellation retain same-context records

    @MainActor func testFailureRetainsRecordsMarkedFailed() async {
        let calls = CallCounter()
        let store = makeStore(load: { _, _ in
            let n = await calls.increment()
            if n == 1 { return self.page([self.userMessage("u1", text: "kept")]) }
            throw TranscriptAPIError.backend(statusCode: 500)
        })
        store.refresh()
        let loaded = await waitUntil { store.messages.count == 1 }
        XCTAssertTrue(loaded)
        store.refresh()
        let failed = await waitUntil { store.lastError == .backend(statusCode: 500) }
        XCTAssertTrue(failed)
        XCTAssertEqual(store.messages, [userMessage("u1", text: "kept")])
        XCTAssertTrue(store.isStale)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testCancellationSettlesNonLoadingRetainingRecords() async {
        let calls = CallCounter()
        let store = makeStore(load: { _, _ in
            let n = await calls.increment()
            if n == 1 { return self.page([self.userMessage("u1", text: "kept")]) }
            throw CancellationError()
        })
        store.refresh()
        let loaded = await waitUntil { store.messages.count == 1 }
        XCTAssertTrue(loaded)
        store.refresh()
        let settled = await waitUntil { !store.isLoading }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.messages, [userMessage("u1", text: "kept")])
        XCTAssertTrue(store.isStale)
        XCTAssertNil(store.lastError)
    }

    // MARK: Repeat snapshot replaces without duplicates

    @MainActor func testRepeatFullRefreshReplacesWithoutDuplicates() async {
        let snapshot = page([userMessage("u1", text: "a"), assistantMessage("m1", text: "b")])
        let store = makeStore(load: { _, _ in snapshot })
        store.refresh()
        let first = await waitUntil { store.messages.count == 2 }
        XCTAssertTrue(first)
        store.refresh()
        let second = await waitUntil { !store.isLoading && store.messages.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(store.messages, Self.presentationOf(snapshot.messages))
    }

    // MARK: Nil context disables transport

    @MainActor func testNilSessionDisablesTransport() async {
        let sessionBox = SessionBox(current: nil)
        let recorder = LoadRecorder()
        let store = makeStore(session: sessionBox, load: { session, query in
            await recorder.record(session: session, query: query)
            return self.page([])
        })
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testNilConnectionDisablesTransport() async {
        let connectionBox = ConnectionBox(generation: nil)
        let recorder = LoadRecorder()
        let store = makeStore(connection: connectionBox, load: { session, query in
            await recorder.record(session: session, query: query)
            return self.page([])
        })
        store.refresh()
        for _ in 0..<20 { await Task.yield() }
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.isLoading)
    }

    // MARK: Server order preserved, reversed exactly once

    @MainActor func testDefaultDescPageReversedOnceWithoutTimestampSort() async {
        // Server order with non-monotonic timestamps: reversal must be exact,
        // proving no timestamp sort sneaks in.
        let serverOrdered = [
            userMessage("u3", text: "third", created: 3),
            userMessage("u1", text: "first", created: 1),
            userMessage("u2", text: "second", created: 2),
        ]
        let store = makeStore(load: { _, query in
            XCTAssertEqual(query.order, .desc)
            return self.page(serverOrdered)
        })
        store.refresh()
        let done = await waitUntil { store.messages.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(store.messages.map(\.messageID), ["u2", "u1", "u3"])
    }

    @MainActor func testNonDescPageKeepsServerOrderDirectly() async {
        let serverOrdered = [
            userMessage("u1", text: "first", created: 3),
            userMessage("u2", text: "second", created: 1),
        ]
        let store = makeStore(load: { _, _ in self.page(serverOrdered) })
        store.refresh(query: TranscriptQuery(limit: 50, order: .asc, cursor: nil))
        let done = await waitUntil { store.messages.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(store.messages.map(\.messageID), ["u1", "u2"])
    }

    // MARK: Opaque entries flow through visibly

    @MainActor func testOpaqueEntriesPassThroughUnchanged() async {
        let opaque = TranscriptMessage.opaque(TranscriptOpaqueMessage(
            id: "msg-unknown-1",
            kind: "future-widget",
            raw: .object(["type": .string("future-widget")])
        ))
        let store = makeStore(load: { _, _ in self.page([opaque, self.userMessage("u1", text: "before")]) })
        store.refresh()
        let done = await waitUntil { store.messages.count == 2 }
        XCTAssertTrue(done)
        // Default desc snapshot presents chronologically: newest (opaque) last.
        guard case .opaque(let fallback) = store.messages.last else {
            return XCTFail("expected trailing opaque entry")
        }
        XCTAssertEqual(fallback.kind, "future-widget")
    }

    private static func presentationOf(_ serverOrdered: [TranscriptMessage]) -> [TranscriptMessage] {
        Array(serverOrdered.reversed())
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

private actor LoadRecorder {
    private var recorded: [(session: SessionID, query: TranscriptQuery)] = []
    func record(session: SessionID, query: TranscriptQuery) { recorded.append((session, query)) }
    func calls() -> [(session: SessionID, query: TranscriptQuery)] { recorded }
    func sessions() -> [SessionID] { recorded.map(\.session) }
    func count() -> Int { recorded.count }
}

private actor ScriptedLoad {
    private var recorded: [(SessionID, TranscriptQuery)] = []
    private var waiters: [Int: CheckedContinuation<TranscriptPage, Error>] = [:]
    private var entered: Set<Int> = []

    func run(session: SessionID, query: TranscriptQuery) async throws -> TranscriptPage {
        let index = recorded.count
        recorded.append((session, query))
        entered.insert(index)
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }

    func waitUntilEntered(_ index: Int) async {
        while !entered.contains(index) { await Task.yield() }
    }

    func resolve(_ index: Int, _ page: TranscriptPage) {
        waiters.removeValue(forKey: index)?.resume(returning: page)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}
