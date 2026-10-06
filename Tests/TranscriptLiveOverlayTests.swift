import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript live overlay tests (H07)
//
// Pure, deterministic tests over `TranscriptLiveOverlay` (value model) and
// `TranscriptLivePublisher` (coalesced publication). No I/O, no wall-clock
// sleeps (a manual scheduler drives flushes), no store wiring, no history
// GETs: the overlay takes no loader by construction — `apply` is synchronous
// and the only inputs are the typed events H06's decoder already produces.

final class TranscriptLiveOverlayTests: XCTestCase {
    private let session = SessionID(rawValue: "ses-live")
    private let otherSession = SessionID(rawValue: "ses-other")

    private func apply(
        _ overlay: inout TranscriptLiveOverlay,
        _ event: SessionTranscriptEvent,
        session: SessionID? = nil
    ) -> TranscriptLiveOverlayOutcome {
        overlay.apply(event, activeSession: session ?? self.session)
    }

    private func started(_ ordinal: Int, message: String = "msg_1") -> SessionTranscriptEvent {
        .textStarted(sessionID: session, messageID: message, ordinal: ordinal, created: 1000)
    }

    private func delta(_ ordinal: Int, _ text: String, message: String = "msg_1") -> SessionTranscriptEvent {
        .textDelta(sessionID: session, messageID: message, ordinal: ordinal, delta: text, created: 1001)
    }

    private func ended(_ ordinal: Int, _ text: String, message: String = "msg_1") -> SessionTranscriptEvent {
        .textEnded(sessionID: session, messageID: message, ordinal: ordinal, text: text, created: 1002)
    }

    // MARK: - Text happy path

    func testTextStartDeltaEndedSettlesSlot() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(apply(&overlay, delta(0, "hel")), .updated)
        XCTAssertEqual(apply(&overlay, delta(0, "lo")), .updated)
        XCTAssertEqual(overlay.items, [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "hello")])
        XCTAssertEqual(
            apply(&overlay, ended(0, "hello")),
            .settled(.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "hello"))
        )
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertTrue(overlay.items.isEmpty)
    }

    func testSettledTextIsTerminalNotAccumulated() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(apply(&overlay, delta(0, "stale-prefix")), .updated)
        // The server's terminal text is authoritative even when it differs
        // from the accumulated deltas.
        XCTAssertEqual(
            apply(&overlay, ended(0, "authoritative full text")),
            .settled(.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "authoritative full text"))
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    func testDeltaWithoutStartIsDropped() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, delta(0, "orphan")), .ignored)
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertTrue(overlay.items.isEmpty)
        // A later start does not resurrect the dropped delta.
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(overlay.items, [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "")])
    }

    func testDuplicateStartDoesNotReset() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(apply(&overlay, delta(0, "kept")), .updated)
        XCTAssertEqual(apply(&overlay, started(0)), .ignored)
        XCTAssertEqual(overlay.items, [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "kept")])
    }

    func testEndedWithoutSlotNeedsMessageRefresh() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, ended(0, "late")), .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertTrue(overlay.isEmpty)
    }

    func testDuplicateEndedIsIgnored() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(
            apply(&overlay, ended(0, "done")),
            .settled(.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "done"))
        )
        XCTAssertEqual(apply(&overlay, ended(0, "done")), .ignored)
        XCTAssertEqual(apply(&overlay, delta(0, "late")), .ignored)
    }

    // MARK: - Reasoning mirrors text

    func testReasoningLifecycle() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(
            apply(&overlay, .reasoningStarted(sessionID: session, messageID: "msg_1", ordinal: 1, created: 1)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .reasoningDelta(sessionID: session, messageID: "msg_1", ordinal: 1, delta: "why", created: 2)),
            .updated
        )
        XCTAssertEqual(overlay.items, [.stream(id: .reasoning(assistantMessageID: "msg_1", ordinal: 1), text: "why")])
        XCTAssertEqual(
            apply(&overlay, .reasoningEnded(sessionID: session, messageID: "msg_1", ordinal: 1, text: "because", created: 3)),
            .settled(.stream(id: .reasoning(assistantMessageID: "msg_1", ordinal: 1), text: "because"))
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    func testReasoningDeltaWithoutStartDroppedAndEndedRefreshes() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(
            apply(&overlay, .reasoningDelta(sessionID: session, messageID: "msg_1", ordinal: 0, delta: "x", created: 1)),
            .ignored
        )
        XCTAssertEqual(
            apply(&overlay, .reasoningEnded(sessionID: session, messageID: "msg_1", ordinal: 0, text: "x", created: 2)),
            .needsMessageRefresh(messageID: "msg_1")
        )
    }

    // MARK: - Ordinal identity

    func testTwoOrdinalsInOneAssistantStayDistinct() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(apply(&overlay, started(1)), .updated)
        XCTAssertEqual(apply(&overlay, delta(0, "zero")), .updated)
        XCTAssertEqual(apply(&overlay, delta(1, "one")), .updated)
        XCTAssertEqual(
            overlay.items,
            [
                .stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "zero"),
                .stream(id: .text(assistantMessageID: "msg_1", ordinal: 1), text: "one"),
            ]
        )
        XCTAssertEqual(
            apply(&overlay, ended(0, "zero")),
            .settled(.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "zero"))
        )
        // Ordinal 1 is untouched by ordinal 0's terminal.
        XCTAssertEqual(overlay.items(for: "msg_1"), [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 1), text: "one")])
        XCTAssertFalse(overlay.isEmpty)
    }

    // MARK: - Tools

    func testToolInputLifecycleSettles() {
        var overlay = TranscriptLiveOverlay()
        let id = LiveContentID.tool(assistantMessageID: "msg_1", toolID: "tool_1")
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 1)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .toolInputDelta(sessionID: session, messageID: "msg_1", toolID: "tool_1", delta: "{\"a\"", created: 2)),
            .updated
        )
        XCTAssertEqual(
            overlay.items,
            [.tool(id: id, name: "read", input: "{\"a\"", metadata: nil)]
        )
        XCTAssertEqual(
            apply(&overlay, .toolInputEnded(sessionID: session, messageID: "msg_1", toolID: "tool_1", text: "{\"a\":1}", created: 3)),
            .settled(.tool(id: id))
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    func testToolProgressUpdatesMetadataAndDropsWithoutSlot() {
        var overlay = TranscriptLiveOverlay()
        let metadata = TranscriptJSONValue.object(["pct": .number(0.5)])
        XCTAssertEqual(
            apply(&overlay, .toolProgress(sessionID: session, messageID: "msg_1", toolID: "tool_1", metadata: metadata, created: 1)),
            .ignored
        )
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 1)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .toolProgress(sessionID: session, messageID: "msg_1", toolID: "tool_1", metadata: metadata, created: 2)),
            .updated
        )
        XCTAssertEqual(
            overlay.items,
            [.tool(id: .tool(assistantMessageID: "msg_1", toolID: "tool_1"), name: "read", input: "", metadata: metadata)]
        )
    }

    func testToolCalledSuccessFailedSettleAndDuplicatesIgnored() {
        for terminal in ["called", "success", "failed"] as [String] {
            var overlay = TranscriptLiveOverlay()
            let id = LiveContentID.tool(assistantMessageID: "msg_1", toolID: "tool_1")
            XCTAssertEqual(
                apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 1)),
                .updated, terminal
            )
            let event: SessionTranscriptEvent
            switch terminal {
            case "called":
                event = .toolCalled(sessionID: session, messageID: "msg_1", toolID: "tool_1", input: .object([:]), created: 2)
            case "success":
                event = .toolSuccess(
                    sessionID: session, messageID: "msg_1", toolID: "tool_1",
                    content: [.text("ok")], executed: true, metadata: nil, created: 2
                )
            default:
                event = .toolFailed(
                    sessionID: session, messageID: "msg_1", toolID: "tool_1",
                    error: TranscriptToolError(type: "E", message: "m", status: nil),
                    executed: false, content: nil, metadata: nil, created: 2
                )
            }
            XCTAssertEqual(apply(&overlay, event), .settled(.tool(id: id)), terminal)
            XCTAssertTrue(overlay.isEmpty, terminal)
            // Duplicates and late arrivals are harmless.
            XCTAssertEqual(apply(&overlay, event), .ignored, terminal)
            XCTAssertEqual(
                apply(&overlay, .toolInputDelta(sessionID: session, messageID: "msg_1", toolID: "tool_1", delta: "late", created: 3)),
                .ignored, terminal
            )
        }
    }

    func testDuplicateToolStartDoesNotReset() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 1)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .toolInputDelta(sessionID: session, messageID: "msg_1", toolID: "tool_1", delta: "partial", created: 2)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 3)),
            .ignored
        )
        XCTAssertEqual(
            overlay.items,
            [.tool(id: .tool(assistantMessageID: "msg_1", toolID: "tool_1"), name: "read", input: "partial", metadata: nil)]
        )
    }

    // MARK: - Step terminals and session scoping

    func testStepEndedClearsOnlyThatAssistant() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0, message: "msg_1")), .updated)
        XCTAssertEqual(apply(&overlay, started(0, message: "msg_2")), .updated)
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_2", toolID: "tool_1", name: "read", created: 1)),
            .updated
        )
        XCTAssertEqual(
            apply(&overlay, .stepEnded(sessionID: session, messageID: "msg_1", finish: "stop", created: 5)),
            .updated
        )
        // msg_1's slots are gone; msg_2's stream and tool overlay survive.
        XCTAssertTrue(overlay.items(for: "msg_1").isEmpty)
        XCTAssertEqual(overlay.items(for: "msg_2").count, 2)
        // Clearing an assistant with no slots is a no-op.
        XCTAssertEqual(
            apply(&overlay, .stepEnded(sessionID: session, messageID: "msg_1", finish: "stop", created: 6)),
            .ignored
        )
        XCTAssertEqual(overlay.items(for: "msg_2").count, 2)
    }

    func testStepFailedClearsAssistantSlots() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(
            apply(
                &overlay,
                .stepFailed(
                    sessionID: session, messageID: "msg_1", finish: "error",
                    error: TranscriptToolError(type: "E", message: "boom", status: nil), created: 5
                )
            ),
            .updated
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    func testStepStartedAndStreamedAreIgnored() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(
            apply(
                &overlay,
                .stepStarted(
                    sessionID: session, messageID: "msg_1", agent: "build",
                    model: TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil),
                    started: 1, created: 1
                )
            ),
            .ignored
        )
        XCTAssertEqual(apply(&overlay, .stepStreamed(sessionID: session, messageID: "msg_1", created: 2)), .ignored)
        XCTAssertTrue(overlay.isEmpty)
    }

    func testWrongSessionEventsAreIgnored() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0), session: otherSession), .ignored)
        XCTAssertEqual(
            overlay.apply(ended(0, "x"), activeSession: otherSession),
            .ignored
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    // MARK: - Clearing, duplicate memory, ordering

    func testClearAndReset() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(0, message: "msg_1")), .updated)
        XCTAssertEqual(apply(&overlay, started(0, message: "msg_2")), .updated)
        XCTAssertTrue(overlay.clear(assistantMessageID: "msg_1"))
        XCTAssertTrue(overlay.items(for: "msg_1").isEmpty)
        XCTAssertEqual(overlay.items(for: "msg_2").count, 1)
        XCTAssertFalse(overlay.clear(assistantMessageID: "msg_1"))
        overlay.reset()
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertTrue(overlay.items.isEmpty)
    }

    func testRecentlySettledSetIsBounded() {
        var overlay = TranscriptLiveOverlay()
        let total = TranscriptLiveOverlay.maximumRecentlySettled + 44
        for ordinal in 0..<total {
            XCTAssertEqual(apply(&overlay, started(ordinal)), .updated, "start \(ordinal)")
            let id = LiveContentID.text(assistantMessageID: "msg_1", ordinal: ordinal)
            XCTAssertEqual(apply(&overlay, ended(ordinal, "t")), .settled(.stream(id: id, text: "t")), "end \(ordinal)")
        }
        XCTAssertTrue(overlay.isEmpty)
        // The earliest settled ids were evicted: a duplicate now degrades to
        // a harmless targeted refresh, never to fabricated content.
        XCTAssertEqual(apply(&overlay, ended(0, "t")), .needsMessageRefresh(messageID: "msg_1"))
        // The most recent ids are still remembered as duplicates.
        let last = LiveContentID.text(assistantMessageID: "msg_1", ordinal: total - 1)
        XCTAssertEqual(apply(&overlay, ended(total - 1, "t")), .ignored)
        _ = last
    }

    func testSnapshotPreservesStartOrderAcrossKinds() {
        var overlay = TranscriptLiveOverlay()
        XCTAssertEqual(apply(&overlay, started(1)), .updated)
        XCTAssertEqual(
            apply(&overlay, .toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_9", name: "bash", created: 2)),
            .updated
        )
        XCTAssertEqual(apply(&overlay, started(0)), .updated)
        XCTAssertEqual(
            overlay.items.map(\.id),
            [
                .text(assistantMessageID: "msg_1", ordinal: 1),
                .tool(assistantMessageID: "msg_1", toolID: "tool_9"),
                .text(assistantMessageID: "msg_1", ordinal: 0),
            ]
        )
    }
}

// MARK: - Publication coalescing tests (H07, manual scheduler, no sleeps)

/// Manual flush scheduler for tests: no wall clock, fully deterministic.
/// Lives in the test target so no test double ships in the app.
@MainActor final class ManualFlushScheduler: TranscriptLiveFlushScheduler {
    private(set) var scheduleCount = 0
    private var tasks: [TranscriptLiveFlushTask] = []

    var pendingCount: Int { tasks.filter { !$0.isCancelled }.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TranscriptLiveFlushTask {
        scheduleCount += 1
        let task = TranscriptLiveFlushTask(action: action)
        tasks.append(task)
        return task
    }

    func firePending() {
        let live = tasks.filter { !$0.isCancelled }
        tasks.removeAll()
        for task in live { task.run() }
    }
}

@MainActor final class TranscriptLivePublisherTests: XCTestCase {
    private let session = SessionID(rawValue: "ses-live")
    private let otherSession = SessionID(rawValue: "ses-other")

    private func started(_ ordinal: Int) -> SessionTranscriptEvent {
        .textStarted(sessionID: session, messageID: "msg_1", ordinal: ordinal, created: 1000)
    }

    private func delta(_ ordinal: Int, _ text: String) -> SessionTranscriptEvent {
        .textDelta(sessionID: session, messageID: "msg_1", ordinal: ordinal, delta: text, created: 1001)
    }

    func testBurstCoalescesToSingleFlush() {
        let scheduler = ManualFlushScheduler()
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler)
        publisher.receive(started(0))
        let count = 5_000
        var expected = ""
        for index in 0..<count {
            let piece = "x\(index);"
            expected.append(piece)
            publisher.receive(delta(0, piece))
        }
        // Thousands of deltas: exactly one pending flush task.
        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(publisher.hasPendingFlush)
        // Nothing is published before the flush runs.
        XCTAssertTrue(publisher.liveItems.isEmpty)
        scheduler.firePending()
        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(publisher.hasPendingFlush)
        XCTAssertEqual(publisher.liveItems, [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: expected)])
        // No idle timer: with nothing dirty, nothing further is scheduled.
        scheduler.firePending()
        XCTAssertEqual(scheduler.scheduleCount, 1)
    }

    func testTerminalFlushesImmediatelyAndCancelsPending() {
        let scheduler = ManualFlushScheduler()
        var outcomes: [TranscriptLiveOverlayOutcome] = []
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler) { outcomes.append($0) }
        publisher.receive(started(0))
        publisher.receive(delta(0, "par"))
        scheduler.firePending()
        XCTAssertEqual(publisher.liveItems, [.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "par")])
        publisher.receive(delta(0, "tial"))
        XCTAssertEqual(scheduler.pendingCount, 1)
        let scheduledBeforeTerminal = scheduler.scheduleCount
        // Terminal event: immediate flush, zero pending tasks, no new schedule.
        publisher.receive(.textEnded(sessionID: session, messageID: "msg_1", ordinal: 0, text: "final", created: 1002))
        XCTAssertEqual(scheduler.scheduleCount, scheduledBeforeTerminal)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(publisher.hasPendingFlush)
        // The settled slot is gone, so the snapshot is empty again.
        XCTAssertTrue(publisher.liveItems.isEmpty)
        XCTAssertEqual(outcomes, [
            .updated,
            .updated,
            .updated,
            .settled(.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "final")),
        ])
    }

    func testUnobservedTerminalFlushesImmediatelyWithoutScheduling() {
        let scheduler = ManualFlushScheduler()
        var outcomes: [TranscriptLiveOverlayOutcome] = []
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler) { outcomes.append($0) }
        publisher.receive(.textEnded(sessionID: session, messageID: "msg_1", ordinal: 0, text: "full", created: 1002))
        XCTAssertEqual(outcomes, [.needsMessageRefresh(messageID: "msg_1")])
        XCTAssertEqual(scheduler.scheduleCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(publisher.liveItems.isEmpty)
    }

    func testIgnoredEventsScheduleNothing() {
        let scheduler = ManualFlushScheduler()
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler)
        // Wrong session.
        publisher.receive(.textStarted(sessionID: otherSession, messageID: "msg_1", ordinal: 0, created: 1))
        // Delta without start.
        publisher.receive(delta(0, "orphan"))
        // Non-overlay event.
        publisher.receive(.stepStreamed(sessionID: session, messageID: "msg_1", created: 1))
        XCTAssertEqual(scheduler.scheduleCount, 0)
        XCTAssertFalse(publisher.hasPendingFlush)
        XCTAssertTrue(publisher.liveItems.isEmpty)
    }

    func testNoIdleTimerOnFreshPublisher() {
        let scheduler = ManualFlushScheduler()
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler)
        _ = publisher
        scheduler.firePending()
        XCTAssertEqual(scheduler.scheduleCount, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testResetClearsPublishedAndPendingState() {
        let scheduler = ManualFlushScheduler()
        let publisher = TranscriptLivePublisher(activeSession: session, scheduler: scheduler)
        publisher.receive(started(0))
        publisher.receive(delta(0, "live"))
        scheduler.firePending()
        XCTAssertEqual(publisher.liveItems.count, 1)
        publisher.receive(delta(0, " more"))
        XCTAssertTrue(publisher.hasPendingFlush)
        publisher.reset()
        XCTAssertTrue(publisher.liveItems.isEmpty)
        XCTAssertFalse(publisher.hasPendingFlush)
        XCTAssertEqual(scheduler.pendingCount, 0)
        scheduler.firePending()
        XCTAssertTrue(publisher.liveItems.isEmpty)
        XCTAssertEqual(scheduler.scheduleCount, 2)
    }
}
