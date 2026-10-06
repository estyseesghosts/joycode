import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript tiered reconciliation tests (H08)
//
// Deterministic tests over a controlled page `load`, a controlled
// single-message `loadMessage`, and hand-delivered fanout signals (no
// network). They pin the tiered model: decoder-covered assistant/tool events
// project locally through the durable reducer and the ephemeral overlay (zero
// reads on a complete sequence), missing prerequisites coalesce into one
// targeted `GET .../message/{id}` per id, and only structural changes fall
// back to one debounced full-page reconciliation. All R08 race machinery is
// retained: generations, readiness, stream failure, initial hydration,
// request generations, tombstones, revert, deletion, and the invalidation
// epoch while a snapshot is in flight.

@MainActor
final class TranscriptReconciliationTests: XCTestCase {
    // MARK: Fixtures

    private func user(_ id: String) -> TranscriptMessage {
        .user(TranscriptTextMessage(id: id, created: 1, text: id))
    }

    private func assistant(
        _ id: String,
        content: [TranscriptContent] = [],
        completed: Double? = nil,
        finish: String? = nil
    ) -> TranscriptMessage {
        .assistant(TranscriptAssistantMessage(
            id: id,
            created: 2000,
            completed: completed,
            agent: "build",
            model: TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil),
            finish: finish,
            error: nil,
            content: content
        ))
    }

    private func completedTool(_ id: String) -> TranscriptContent {
        .tool(TranscriptToolContent(
            id: id,
            name: "read",
            created: 2000,
            state: .completed(input: .object([:]), content: [.text("ok")], metadata: nil)
        ))
    }

    /// Server order is newest first; the store reverses once for display.
    private func page(_ ids: String...) -> TranscriptPage {
        TranscriptPage(messages: ids.map(user), cursor: TranscriptCursor(previous: nil, next: nil))
    }

    private func ids(_ store: TranscriptStore) -> [String?] {
        store.messages.map(\.messageID)
    }

    private func onlyAssistant(_ store: TranscriptStore, _ id: String) throws -> TranscriptAssistantMessage {
        let rows = store.messages.filter { $0.messageID == id }
        XCTAssertEqual(rows.count, 1)
        guard case .assistant(let assistant) = try XCTUnwrap(rows.first) else {
            throw TestFailure.expectedAssistant
        }
        return assistant
    }

    private enum TestFailure: Error {
        case expectedAssistant
    }

    // MARK: Envelope builders (real JSON path, so the decoder is exercised)

    private func envelope(_ type: String, data: String) throws -> EventEnvelope {
        let json = "{\"id\":\"evt-t\",\"type\":\"\(type)\",\"created\":1000,\"data\":{\(data)}}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    private func signal(
        _ type: String,
        _ data: String = "",
        session: String? = "ses-1",
        generation: UInt64 = 1
    ) throws -> ConnectionEventSignal {
        var fields: [String] = []
        if let session { fields.append("\"sessionID\":\"\(session)\"") }
        if !data.isEmpty { fields.append(data) }
        return .event(generation: generation, envelope: try envelope(type, data: fields.joined(separator: ",")))
    }

    private func base(_ message: String, session: String = "ses-1") -> String {
        "\"sessionID\":\"\(session)\",\"assistantMessageID\":\"\(message)\""
    }

    private func stepStarted(_ message: String) throws -> ConnectionEventSignal {
        try signal(
            "session.step.started",
            "\(base(message)),\"agent\":\"build\"," +
            "\"model\":{\"id\":\"m\",\"providerID\":\"openrouter\"},\"started\":2000"
        )
    }

    private func stepEnded(_ message: String) throws -> ConnectionEventSignal {
        try signal(
            "session.step.ended",
            "\(base(message)),\"finish\":\"stop\",\"cost\":1.5,\"tokens\":{\"input\":1,\"output\":2}"
        )
    }

    private func textStarted(_ message: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.text.started", "\(base(message)),\"ordinal\":\(ordinal)")
    }

    private func textDelta(_ message: String, _ delta: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.text.delta", "\(base(message)),\"ordinal\":\(ordinal),\"delta\":\"\(delta)\"")
    }

    private func textEnded(_ message: String, _ text: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.text.ended", "\(base(message)),\"ordinal\":\(ordinal),\"text\":\"\(text)\"")
    }

    private func reasoningStarted(_ message: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.reasoning.started", "\(base(message)),\"ordinal\":\(ordinal)")
    }

    private func reasoningDelta(_ message: String, _ delta: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.reasoning.delta", "\(base(message)),\"ordinal\":\(ordinal),\"delta\":\"\(delta)\"")
    }

    private func reasoningEnded(_ message: String, _ text: String, ordinal: Int = 0) throws -> ConnectionEventSignal {
        try signal("session.reasoning.ended", "\(base(message)),\"ordinal\":\(ordinal),\"text\":\"\(text)\"")
    }

    private func toolInputStarted(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal("session.tool.input.started", "\(base(message)),\"id\":\"\(tool)\",\"name\":\"read\"")
    }

    private func toolInputDelta(_ message: String, _ tool: String, _ delta: String) throws -> ConnectionEventSignal {
        try signal("session.tool.input.delta", "\(base(message)),\"id\":\"\(tool)\",\"delta\":\"\(delta)\"")
    }

    private func toolInputEnded(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal("session.tool.input.ended", "\(base(message)),\"id\":\"\(tool)\",\"text\":\"{}\"")
    }

    private func toolCalled(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal("session.tool.called", "\(base(message)),\"id\":\"\(tool)\",\"input\":{},\"executed\":true")
    }

    private func toolProgress(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal("session.tool.progress", "\(base(message)),\"id\":\"\(tool)\",\"metadata\":{\"pct\":0.5}")
    }

    private func toolSuccess(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal(
            "session.tool.success",
            "\(base(message)),\"id\":\"\(tool)\",\"executed\":true," +
            "\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]"
        )
    }

    private func toolFailed(_ message: String, _ tool: String) throws -> ConnectionEventSignal {
        try signal(
            "session.tool.failed",
            "\(base(message)),\"id\":\"\(tool)\",\"executed\":true," +
            "\"error\":{\"type\":\"E\",\"message\":\"bad\"}"
        )
    }

    private func executionSucceeded() throws -> ConnectionEventSignal {
        try signal("session.execution.succeeded")
    }

    // MARK: Harness

    private struct Harness {
        let store: TranscriptStore
        let load: ReconLoad
        let messages: MessageLoad
        let scheduler: ManualFlushScheduler
        let session: ReconSessionBox
        let connection: ReconConnectionBox
    }

    private func harness(awaitsEventStream: Bool = true) -> Harness {
        let load = ReconLoad()
        let messages = MessageLoad()
        let scheduler = ManualFlushScheduler()
        let session = ReconSessionBox(SessionID(rawValue: "ses-1"))
        let connection = ReconConnectionBox(1)
        let store = TranscriptStore(
            activeSessionID: { session.current },
            connectionGeneration: { connection.generation },
            awaitsEventStream: awaitsEventStream,
            resyncDelay: .zero,
            load: { id, query in try await load.run(session: id, query: query) },
            loadMessage: { id, messageID in try await messages.run(session: id, messageID: messageID) },
            liveFlushScheduler: scheduler
        )
        return Harness(store: store, load: load, messages: messages, scheduler: scheduler, session: session, connection: connection)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Deterministic drain without fixed-duration sleeps: all scheduling in
    /// the store happens synchronously inside `receive`, so yielding lets
    /// already-created tasks run to their next suspension point.
    private func drain(_ rounds: Int = 100) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    /// Ready stream and a published first snapshot.
    private func liveHarness(_ page: TranscriptPage) async throws -> Harness {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let entered = await h.load.waitForCalls(1)
        XCTAssertTrue(entered)
        await h.load.resolve(0, page)
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        return h
    }

    private func assertUniquePresentation(
        _ store: TranscriptStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var seen = Set<TranscriptPresentationID>()
        var total = 0
        for row in store.presentationRows {
            total += 1
            XCTAssertTrue(seen.insert(row.id).inserted, "duplicate row id", file: file, line: line)
            for item in row.contents {
                total += 1
                XCTAssertTrue(seen.insert(item.id).inserted, "duplicate content id", file: file, line: line)
            }
            for live in row.liveItems {
                total += 1
                XCTAssertTrue(seen.insert(.live(live.id)).inserted, "duplicate live id", file: file, line: line)
            }
        }
        XCTAssertEqual(seen.count, total, file: file, line: line)
    }

    // MARK: Readiness gating

    func testNoSnapshotBeforeReadinessThenHydratesAfterConnected() async throws {
        let h = harness()
        h.store.contextChanged()
        await drain(20)
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

    // MARK: Structural invalidation, coalescing, and ordering

    func testEventDuringFetchPublishesReplyAsResyncingThenFollowsUp() async throws {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)

        // Structural edge event (execution terminal row): the in-flight fetch
        // is not cancelled or duplicated by the event.
        h.store.receive(try executionSucceeded())
        await drain()
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
        let h = try await liveHarness(page("m1"))
        for _ in 0..<12 { h.store.receive(try executionSucceeded()) }
        XCTAssertEqual(h.store.synchronization, .resyncing)
        let started = await h.load.waitForCalls(2)
        XCTAssertTrue(started)
        await drain()
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
        let h = try await liveHarness(page("m1"))
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
        await drain()
        XCTAssertEqual(ids(h.store), ["m1", "m2", "m3"])
    }

    func testOverlayOnlyAndStatusEventsNeverRead() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        // Attributed ephemeral events: deltas without slots are dropped, tool
        // progress without a slot changes nothing, and status/usage/execution
        // starts are structurally inert.
        h.store.receive(try textDelta("msgA", "orphan"))
        h.store.receive(try reasoningDelta("msgA", "orphan"))
        h.store.receive(try toolProgress("msgA", "tool_9"))
        h.store.receive(try toolInputDelta("msgA", "tool_9", "orphan"))
        h.store.receive(try signal("session.status"))
        h.store.receive(try signal("session.usage.updated"))
        h.store.receive(try signal("session.execution.started"))
        h.store.receive(try signal("session.compaction.delta"))
        await drain()
        let pages = await h.load.callCount()
        XCTAssertEqual(pages, 1)
        let singles = await h.messages.callCount()
        XCTAssertEqual(singles, 0)
        XCTAssertEqual(h.store.synchronization, .live)
        XCTAssertEqual(h.scheduler.scheduleCount, 0)
        XCTAssertTrue(h.store.liveItems.isEmpty)
    }

    func testEventsForOtherSessionsAndGenerationsAreIgnored() async throws {
        let h = try await liveHarness(page("m1"))
        h.store.receive(try signal("session.tool.success", "\"assistantMessageID\":\"msgA\",\"id\":\"t\"", session: "ses-other"))
        h.store.receive(try signal("session.deleted", session: "ses-other"))
        h.store.receive(try signal("session.revert.committed", "\"to\":\"m1\"", session: "ses-other"))
        h.store.receive(try signal("session.tool.success", generation: 7))
        h.store.receive(.failed(generation: 7))
        await drain()
        let count = await h.load.callCount()
        XCTAssertEqual(count, 1)
        let singles = await h.messages.callCount()
        XCTAssertEqual(singles, 0)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testUnroutableAndUnknownSessionEventsRefreshTheActiveSession() async throws {
        let h = try await liveHarness(page("m1"))
        // No session attribution on a non-decoder family: unroutable, so the
        // active session refreshes rather than guessing.
        h.store.receive(try signal("session.execution.succeeded", session: nil))
        let first = await h.load.waitForCalls(2)
        XCTAssertTrue(first)
        await h.load.resolve(1, page("m1"))
        let settledOnce = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(settledOnce)

        h.store.receive(try signal("session.future.thing"))
        let second = await h.load.waitForCalls(3)
        XCTAssertTrue(second)
        await h.load.resolve(2, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
    }

    // MARK: Tier A — complete execution needs zero reads

    func testCompleteExecutionNeedsNoReads() async throws {
        let baseline = TranscriptPage(
            messages: [user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try stepStarted("msgA"))
        h.store.receive(try textStarted("msgA"))
        for index in 0..<40 {
            h.store.receive(try textDelta("msgA", "t\(index);"))
        }
        h.store.receive(try textEnded("msgA", "hello"))
        h.store.receive(try reasoningStarted("msgA"))
        for index in 0..<40 {
            h.store.receive(try reasoningDelta("msgA", "r\(index);"))
        }
        h.store.receive(try reasoningEnded("msgA", "why"))
        for tool in 0..<100 {
            let id = "tool_\(tool)"
            h.store.receive(try toolInputStarted("msgA", id))
            h.store.receive(try toolInputDelta("msgA", id, "a"))
            h.store.receive(try toolInputDelta("msgA", id, "b"))
            h.store.receive(try toolInputEnded("msgA", id))
            h.store.receive(try toolCalled("msgA", id))
            h.store.receive(try toolProgress("msgA", id))
            h.store.receive(try toolProgress("msgA", id))
            h.store.receive(try toolProgress("msgA", id))
            if tool % 10 == 9 {
                h.store.receive(try toolFailed("msgA", id))
            } else {
                h.store.receive(try toolSuccess("msgA", id))
            }
            if tool % 25 == 24 {
                h.scheduler.firePending()
                assertUniquePresentation(h.store)
            }
        }
        h.store.receive(try stepEnded("msgA"))
        await drain()

        let pages = await h.load.callCount()
        XCTAssertEqual(pages, 1)
        let singles = await h.messages.callCount()
        XCTAssertEqual(singles, 0)

        let rows = h.store.presentationRows
        XCTAssertEqual(rows.count, 2)
        let assistant = try onlyAssistant(h.store, "msgA")
        let texts = assistant.content.compactMap { content -> String? in
            if case .text(let value) = content { return value }
            return nil
        }
        XCTAssertEqual(texts, ["hello"])
        let reasonings = assistant.content.compactMap { content -> String? in
            if case .reasoning(let value) = content { return value }
            return nil
        }
        XCTAssertEqual(reasonings, ["why"])
        let tools = assistant.content.compactMap { content -> TranscriptToolContent? in
            if case .tool(let tool) = content { return tool }
            return nil
        }
        XCTAssertEqual(tools.count, 100)
        XCTAssertEqual(Set(tools.map(\.id)).count, 100)
        var completed = 0
        var errored = 0
        for tool in tools {
            switch tool.state {
            case .completed: completed += 1
            case .error: errored += 1
            default: XCTFail("tool \(tool.id) is not terminal")
            }
        }
        XCTAssertEqual(completed, 90)
        XCTAssertEqual(errored, 10)
        // No empty started items left unsettled, no duplicates.
        XCTAssertFalse(assistant.content.contains { $0 == .text("") })
        XCTAssertFalse(assistant.content.contains { $0 == .reasoning("") })
        assertUniquePresentation(h.store)
        XCTAssertTrue(h.store.liveItems.isEmpty)
        XCTAssertEqual(h.store.synchronization, .live)
        XCTAssertEqual(h.scheduler.pendingCount, 0)
    }

    // MARK: Tier B — missing prerequisite yields one targeted read

    func testMissingToolPrerequisiteTriggersSingleMessageRead() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        // Terminal without any prior tool events: never fabricated, exactly
        // one message GET (not a page GET).
        h.store.receive(try toolSuccess("msgA", "tool_X"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        await drain()
        let reads2 = await h.messages.callCount()
        XCTAssertEqual(reads2, 1)
        let reads3 = await h.load.callCount()
        XCTAssertEqual(reads3, 1)
        // No fabricated tool before the authoritative response lands.
        let before = try onlyAssistant(h.store, "msgA")
        XCTAssertEqual(before.content, [.text("hi")])
        XCTAssertEqual(h.store.synchronization, .resyncing)

        let serverRow = assistant("msgA", content: [.text("hi"), completedTool("tool_X")])
        await h.messages.resolve(0, serverRow)
        let merged = await waitUntil { (try? self.onlyAssistant(h.store, "msgA"))?.content == [.text("hi"), self.completedTool("tool_X")] }
        XCTAssertTrue(merged)
        // Replace in place: unrelated rows unmoved and unreordered.
        XCTAssertEqual(ids(h.store), ["u1", "msgA"])
        XCTAssertEqual(h.store.synchronization, .live)
        let reads4 = await h.load.callCount()
        XCTAssertEqual(reads4, 1)
    }

    // MARK: Tier C — unknown structural event reconciles exactly once

    func testUnknownStructuralEventReconcilesExactlyOnce() async throws {
        let h = try await liveHarness(page("m1"))
        for _ in 0..<12 { h.store.receive(try signal("session.future.thing")) }
        let started = await h.load.waitForCalls(2)
        XCTAssertTrue(started)
        await drain()
        let reads5 = await h.load.callCount()
        XCTAssertEqual(reads5, 2)
        let reads6 = await h.messages.callCount()
        XCTAssertEqual(reads6, 0)
        await h.load.resolve(1, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
    }

    func testExecutionSucceededTriggersExactlyOnePageRead() async throws {
        let h = try await liveHarness(page("m1"))
        for _ in 0..<10 { h.store.receive(try executionSucceeded()) }
        let started = await h.load.waitForCalls(2)
        XCTAssertTrue(started)
        await drain()
        // Execution terminal idles into one reconciliation; nothing reads
        // during tool execution itself (see tier A).
        let reads7 = await h.load.callCount()
        XCTAssertEqual(reads7, 2)
        let reads8 = await h.messages.callCount()
        XCTAssertEqual(reads8, 0)
        await h.load.resolve(1, page("m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
    }

    // MARK: Tier D — malformed coalescing, dirty re-reads, escalation

    /// Recognized type with broken fields but usable attribution: not
    /// applicable to the reducer, so each id reconciles its own message.
    private func malformedToolSuccess(_ message: String) throws -> ConnectionEventSignal {
        try signal("session.tool.success", "\(base(message)),\"id\":\"tool_1\"")
    }

    func testMalformedBurstCoalescesToOneMessageReadPerID() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgY"), assistant("msgX"), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        for _ in 0..<20 { h.store.receive(try malformedToolSuccess("msgX")) }
        for _ in 0..<3 { h.store.receive(try malformedToolSuccess("msgY")) }
        let started = await h.messages.waitForCalls(2)
        XCTAssertTrue(started)
        await drain()
        // Exactly one outstanding GET per id, no page reads.
        let reads9 = await h.messages.callCount()
        XCTAssertEqual(reads9, 2)
        let reads10 = await h.load.callCount()
        XCTAssertEqual(reads10, 1)
        let reads1 = await h.messages.ids()
        XCTAssertEqual(Set(reads1), Set(["msgX", "msgY"]))

        await h.messages.resolve(0, assistant("msgX", content: [.text("sx")]))
        await h.messages.resolve(1, assistant("msgY", content: [.text("sy")]))
        let merged = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(merged)
        XCTAssertEqual((try onlyAssistant(h.store, "msgX")).content, [.text("sx")])
        XCTAssertEqual((try onlyAssistant(h.store, "msgY")).content, [.text("sy")])
        let reads11 = await h.load.callCount()
        XCTAssertEqual(reads11, 1)
    }

    func testInFlightEventMarksDirtyAndRereadsOnce() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgX", content: [.text("old")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try malformedToolSuccess("msgX"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        // A durable-affecting event while in flight marks dirty.
        h.store.receive(try malformedToolSuccess("msgX"))
        await h.messages.resolve(0, assistant("msgX", content: [.text("stale")]))
        let reread = await h.messages.waitForCalls(2)
        XCTAssertTrue(reread)
        // The first (pre-event) response is discarded, never merged.
        await drain()
        XCTAssertEqual((try onlyAssistant(h.store, "msgX")).content, [.text("old")])
        await h.messages.resolve(1, assistant("msgX", content: [.text("new")]))
        let merged = await waitUntil { (try? self.onlyAssistant(h.store, "msgX"))?.content == [.text("new")] }
        XCTAssertTrue(merged)
        let reads12 = await h.messages.callCount()
        XCTAssertEqual(reads12, 2)
        let reads13 = await h.load.callCount()
        XCTAssertEqual(reads13, 1)
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testRepeatedDirtyDiscardsEscalateToFullReconciliation() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgX", content: [.text("old")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try malformedToolSuccess("msgX"))
        for round in 1...3 {
            let started = await h.messages.waitForCalls(round)
            XCTAssertTrue(started)
            h.store.receive(try malformedToolSuccess("msgX"))
            await h.messages.resolve(round - 1, assistant("msgX", content: [.text("stale-\(round)")]))
        }
        // Three consecutive dirty discards escalate to exactly one page read.
        let escalated = await h.load.waitForCalls(2)
        XCTAssertTrue(escalated)
        await drain()
        let reads14 = await h.messages.callCount()
        XCTAssertEqual(reads14, 3)
        let reads15 = await h.load.callCount()
        XCTAssertEqual(reads15, 2)
        // Stale targeted responses never merged.
        XCTAssertEqual((try onlyAssistant(h.store, "msgX")).content, [.text("old")])
        await h.load.resolve(1, TranscriptPage(
            messages: [assistant("msgX", content: [.text("fresh")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        ))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual((try onlyAssistant(h.store, "msgX")).content, [.text("fresh")])
    }

    // MARK: Tier E — bursts of complete events cause no page reads

    func testBurstOfCompleteEventsCausesNoPageReads() async throws {
        let baseline = TranscriptPage(
            messages: [user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try stepStarted("msgA"))
        h.store.receive(try textStarted("msgA"))
        h.store.receive(try textDelta("msgA", "hel"))
        h.store.receive(try textDelta("msgA", "lo"))
        h.store.receive(try textEnded("msgA", "hello"))
        h.store.receive(try toolInputStarted("msgA", "tool_1"))
        h.store.receive(try toolInputEnded("msgA", "tool_1"))
        h.store.receive(try toolCalled("msgA", "tool_1"))
        h.store.receive(try toolSuccess("msgA", "tool_1"))
        h.store.receive(try reasoningStarted("msgA"))
        h.store.receive(try reasoningEnded("msgA", "why"))
        h.store.receive(try stepEnded("msgA"))
        await drain()
        let reads16 = await h.load.callCount()
        XCTAssertEqual(reads16, 1)
        let reads17 = await h.messages.callCount()
        XCTAssertEqual(reads17, 0)
        XCTAssertEqual(h.store.synchronization, .live)
        let assistant = try onlyAssistant(h.store, "msgA")
        XCTAssertEqual(assistant.content.first, .text("hello"))
        XCTAssertEqual(assistant.content.last, .reasoning("why"))
        XCTAssertTrue(h.store.liveItems.isEmpty)
    }

    // MARK: Targeted merge rules

    func testAbsentMessageResponseEscalatesToPageReadWithoutReordering() async throws {
        let h = try await liveHarness(page("m1"))
        // Unknown assistant: the reducer cannot project, so one message GET.
        h.store.receive(try toolSuccess("msgGhost", "tool_1"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        // The ghost is absent from the window: escalate to one page read
        // rather than inventing an insertion point.
        await h.messages.resolve(0, assistant("msgGhost", content: [.text("boo")]))
        let escalated = await h.load.waitForCalls(2)
        XCTAssertTrue(escalated)
        await drain()
        XCTAssertEqual(ids(h.store), ["m1"])
        let reads18 = await h.load.callCount()
        XCTAssertEqual(reads18, 2)
        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testMessageNotFoundEscalatesAndDoesNotWedge() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try toolSuccess("msgA", "tool_X"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        // 404: the server no longer holds the message, so the window cannot
        // be trusted; exactly one full reconciliation, entry removed.
        await h.messages.fail(0, TranscriptAPIError.notFound)
        let escalated = await h.load.waitForCalls(2)
        XCTAssertTrue(escalated)
        await h.load.resolve(1, TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        ))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        // The table is not wedged: a later event for the same id reads again.
        h.store.receive(try toolSuccess("msgA", "tool_X"))
        let reread = await h.messages.waitForCalls(2)
        XCTAssertTrue(reread)
        await h.messages.resolve(1, assistant("msgA", content: [.text("hi"), completedTool("tool_X")]))
        let merged = await waitUntil { (try? self.onlyAssistant(h.store, "msgA"))?.content == [.text("hi"), self.completedTool("tool_X")] }
        XCTAssertTrue(merged)
        let reads19 = await h.load.callCount()
        XCTAssertEqual(reads19, 2)
    }

    func testMessageFailureEscalatesAndDoesNotWedge() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try toolSuccess("msgA", "tool_X"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        await h.messages.fail(0, TranscriptAPIError.requestFailed)
        let escalated = await h.load.waitForCalls(2)
        XCTAssertTrue(escalated)
        await h.load.resolve(1, TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        ))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        h.store.receive(try toolSuccess("msgA", "tool_X"))
        let reread = await h.messages.waitForCalls(2)
        XCTAssertTrue(reread)
    }

    func testContextChangeClearsPendingReadAndDropsLateResponse() async throws {
        let h = try await liveHarness(page("m1"))
        h.store.receive(try toolSuccess("msgGhost", "tool_1"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)

        h.session.current = SessionID(rawValue: "ses-2")
        h.store.contextChanged()
        let other = await h.load.waitForCalls(2)
        XCTAssertTrue(other)
        // The late targeted response for the old session is dropped: no
        // merge, no extra reconciliation.
        await h.messages.resolve(0, assistant("msgGhost", content: [.text("boo")]))
        await h.load.resolve(1, page("x1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["x1"])
        await drain()
        let reads20 = await h.messages.callCount()
        XCTAssertEqual(reads20, 1)
        let reads21 = await h.load.callCount()
        XCTAssertEqual(reads21, 2)
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testStaleConnectionResponseDropped() async throws {
        let h = try await liveHarness(page("m1"))
        h.store.receive(try toolSuccess("msgGhost", "tool_1"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)

        h.connection.generation = 2
        h.store.contextChanged()
        XCTAssertTrue(h.store.messages.isEmpty)
        await h.messages.resolve(0, assistant("msgGhost", content: [.text("boo")]))
        await drain()
        // Stale connection: dropped, and the new generation still awaits its
        // readiness marker before hydrating.
        XCTAssertTrue(h.store.messages.isEmpty)
        let reads22 = await h.messages.callCount()
        XCTAssertEqual(reads22, 1)
        let reads23 = await h.load.callCount()
        XCTAssertEqual(reads23, 1)
        XCTAssertEqual(h.store.synchronization, .awaitingStream)
    }

    // MARK: Stream settlement edges

    func testTextEndedWithoutObservedStartTriggersTargetedRead() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA", content: [.text("hi")]), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try textEnded("msgA", "hello"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        await drain()
        let reads24 = await h.load.callCount()
        XCTAssertEqual(reads24, 1)
        await h.messages.resolve(0, assistant("msgA", content: [.text("hello")]))
        let merged = await waitUntil { (try? self.onlyAssistant(h.store, "msgA"))?.content == [.text("hello")] }
        XCTAssertTrue(merged)
        XCTAssertEqual(h.store.synchronization, .live)
    }

    func testTextEndedAfterSnapshotPublishTriggersTargetedRead() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA"), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try textStarted("msgA"))
        // An intervening snapshot publish clears the ordinal mapping, so the
        // later terminal cannot settle locally even though the start was seen.
        h.store.refresh()
        let snapshot = await h.load.waitForCalls(2)
        XCTAssertTrue(snapshot)
        await h.load.resolve(1, TranscriptPage(
            messages: [assistant("msgA"), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        ))
        // Drain on the publish landing, not just `.live`: the pre-refresh
        // baseline already reports `.live` while the refresh is in flight.
        let landed = await waitUntil { !h.store.isLoading }
        XCTAssertTrue(landed)
        let republished = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(republished)
        h.store.receive(try textEnded("msgA", "hello"))
        let started = await h.messages.waitForCalls(1)
        XCTAssertTrue(started)
        await h.messages.resolve(0, assistant("msgA", content: [.text("hello")]))
        let merged = await waitUntil { (try? self.onlyAssistant(h.store, "msgA"))?.content == [.text("hello")] }
        XCTAssertTrue(merged)
    }

    func testDuplicateTextEndedHarmless() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA"), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try textStarted("msgA"))
        h.store.receive(try textEnded("msgA", "hi"))
        h.store.receive(try textEnded("msgA", "hi"))
        await drain()
        let reads25 = await h.messages.callCount()
        XCTAssertEqual(reads25, 0)
        let reads26 = await h.load.callCount()
        XCTAssertEqual(reads26, 1)
        XCTAssertEqual((try onlyAssistant(h.store, "msgA")).content, [.text("hi")])
        XCTAssertEqual(h.store.synchronization, .live)
    }

    // MARK: Hydration races (durable events never apply without a baseline)

    func testDurableEventDuringFirstSnapshotIsNotApplied() async throws {
        let h = harness()
        h.store.contextChanged()
        h.store.receive(.connected(generation: 1))
        let first = await h.load.waitForCalls(1)
        XCTAssertTrue(first)

        // No published baseline yet: the step is NOT projected and instead
        // invalidates the in-flight snapshot.
        h.store.receive(try stepStarted("msgA"))
        await drain()
        XCTAssertTrue(h.store.messages.isEmpty)

        await h.load.resolve(0, page("m1"))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        XCTAssertEqual(h.store.synchronization, .resyncing)
        await h.load.resolve(1, page("m2", "m1"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testDurableEventDuringResyncSnapshotInvalidatesIt() async throws {
        let h = try await liveHarness(page("m1"))
        h.store.refresh()
        let second = await h.load.waitForCalls(2)
        XCTAssertTrue(second)

        // A snapshot is in flight: the new step is NOT projected locally and
        // the in-flight reply publishes as resyncing with a follow-up read.
        h.store.receive(try stepStarted("msgB"))
        await drain()
        XCTAssertEqual(ids(h.store), ["m1"])

        await h.load.resolve(1, page("m1"))
        let followUp = await h.load.waitForCalls(3)
        XCTAssertTrue(followUp)
        XCTAssertEqual(h.store.synchronization, .resyncing)
        await h.load.resolve(2, TranscriptPage(
            messages: [assistant("msgB"), user("m1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        ))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["m1", "msgB"])
    }

    // MARK: Removals

    func testRevertCommittedTruncatesDisplayAtBoundaryThenResyncs() async throws {
        let h = try await liveHarness(page("m4", "m3", "m2", "m1"))
        XCTAssertEqual(ids(h.store), ["m1", "m2", "m3", "m4"])
        h.store.receive(try signal("session.revert.committed", "\"to\":\"m3\""))
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

        h.store.receive(try signal("session.revert.committed", "\"to\":\"m3\""))
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
        let h = try await liveHarness(page("m4", "m3", "m2", "m1"))
        h.store.receive(try signal("session.revert.committed", "\"to\":\"m3\""))
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        // A lagging read that still contains removed records cannot revive them.
        await h.load.resolve(1, page("m4", "m3", "m2", "m1"))
        let settled = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(settled)
        XCTAssertEqual(ids(h.store), ["m1", "m2"])
    }

    func testRevertBoundaryNotDisplayedKeepsDisplayButIsNotLive() async throws {
        let h = try await liveHarness(page("m2", "m1"))
        h.store.receive(try signal("session.revert.committed", "\"to\":\"m9\""))
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
        let h = try await liveHarness(page("m1"))
        h.store.receive(try signal("session.deleted"))
        XCTAssertTrue(h.store.messages.isEmpty)
        XCTAssertEqual(h.store.synchronization, .sessionRemoved)
        XCTAssertEqual(h.store.unavailableMessage, "This session was deleted.")

        h.store.refresh()
        h.store.receive(try executionSucceeded())
        h.store.receive(.connected(generation: 1))
        await drain()
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
        await drain()
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
        await drain()
        XCTAssertTrue(h.store.messages.isEmpty)
        await h.load.resolve(1, page("new"))
        let live = await waitUntil { h.store.synchronization == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(ids(h.store), ["new"])
        XCTAssertEqual(h.store.publishedSessionID, SessionID(rawValue: "ses-2"))
    }

    func testConnectionReplacementWaitsForNewReadinessAndIgnoresOldSignals() async throws {
        let h = try await liveHarness(page("m1"))
        h.connection.generation = 2
        h.store.contextChanged()
        XCTAssertTrue(h.store.messages.isEmpty)
        XCTAssertEqual(h.store.synchronization, .awaitingStream)

        // Late signals from the replaced generation are ignored.
        h.store.receive(.connected(generation: 1))
        h.store.receive(try executionSucceeded())
        await drain()
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
        let h = try await liveHarness(page("m1"))
        h.store.receive(.failed(generation: 1))
        XCTAssertEqual(h.store.synchronization, .streamLost)
        XCTAssertEqual(ids(h.store), ["m1"])
        XCTAssertFalse(h.store.messages.isEmpty)
    }

    func testFailedFollowUpKeepsRecordsAndReportsRefreshFailure() async throws {
        let h = try await liveHarness(page("m1"))
        h.store.receive(try executionSucceeded())
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

        fanout.deliver(try executionSucceeded())
        let followUp = await h.load.waitForCalls(2)
        XCTAssertTrue(followUp)
        await h.load.resolve(1, page("m2", "m1"))
        let updated = await waitUntil { self.ids(h.store) == ["m1", "m2"] }
        XCTAssertTrue(updated)

        fanout.deliver(.failed(generation: 1))
        XCTAssertEqual(h.store.synchronization, .streamLost)
    }

    // MARK: Overlay publication coalescing

    func testOverlayOnlyEventsCoalesceToOneFlush() async throws {
        let baseline = TranscriptPage(
            messages: [assistant("msgA"), user("u1")],
            cursor: TranscriptCursor(previous: nil, next: nil)
        )
        let h = try await liveHarness(baseline)
        h.store.receive(try textStarted("msgA"))
        for index in 0..<5_000 {
            h.store.receive(try textDelta("msgA", "x\(index);"))
        }
        // Thousands of ephemeral deltas: at most one pending flush task, and
        // overlay-only events never read.
        XCTAssertLessThanOrEqual(h.scheduler.pendingCount, 1)
        XCTAssertEqual(h.scheduler.scheduleCount, 1)
        let reads27 = await h.messages.callCount()
        XCTAssertEqual(reads27, 0)
        let reads28 = await h.load.callCount()
        XCTAssertEqual(reads28, 1)
        XCTAssertEqual(h.store.synchronization, .live)
        h.scheduler.firePending()
        XCTAssertEqual(h.scheduler.pendingCount, 0)
        XCTAssertEqual(h.store.liveItems.count, 1)
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

/// Suspends every page call until the test resolves or fails it by call index.
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

/// Suspends every single-message call until the test resolves or fails it by
/// call index, recording the requested ids so coalescing is observable.
private actor MessageLoad {
    private var requestLog: [(session: SessionID, messageID: String)] = []
    private var waiters: [Int: CheckedContinuation<TranscriptMessage, Error>] = [:]

    func run(session: SessionID, messageID: String) async throws -> TranscriptMessage {
        let index = requestLog.count
        requestLog.append((session, messageID))
        return try await withCheckedThrowingContinuation { waiters[index] = $0 }
    }

    func callCount() -> Int { requestLog.count }

    func ids() -> [String] { requestLog.map(\.messageID) }

    func waitForCalls(_ count: Int) async -> Bool {
        for _ in 0..<300 {
            if requestLog.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return requestLog.count >= count
    }

    func resolve(_ index: Int, _ message: TranscriptMessage) {
        waiters.removeValue(forKey: index)?.resume(returning: message)
    }

    func fail(_ index: Int, _ error: Error) {
        waiters.removeValue(forKey: index)?.resume(throwing: error)
    }
}
