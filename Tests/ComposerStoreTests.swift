import Foundation
import XCTest
@testable import Joycode

// MARK: - Composer store tests (R06 draft + prompt submission slice)

final class ComposerStoreTests: XCTestCase {
    // MARK: Fixtures

    private static func readyContext(
        session: String? = "ses-A",
        directory: URL? = URL(fileURLWithPath: "/work"),
        generation: UInt64? = 7,
        isReady: Bool = true
    ) -> ComposerContext {
        ComposerContext(
            sessionID: session.map(SessionID.init(rawValue:)),
            directory: directory,
            connectionGeneration: generation,
            isReady: isReady
        )
    }

    private static func admitted(for request: PromptRequest) -> PromptSendResult {
        .admitted(
            PromptAdmittedMessage(
                id: request.messageID,
                sessionID: request.sessionID.rawValue,
                type: "user",
                time: PromptInboxTime(created: 1_700_000_000_000),
                payload: PromptInboxPayload(text: request.text),
                delivery: .steer
            )
        )
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @MainActor private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor private func makeStore(box: ComposerContextBox, send: @escaping ComposerSendAction) -> ComposerStore {
        ComposerStore(context: { box.context }, send: send)
    }

    // MARK: Eligibility

    @MainActor func testQueuedReadinessChangeDoesNotDispatch() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("preserved")
        store.send()
        box.context = Self.readyContext(isReady: false)
        let settled = await waitUntil { if case .rejected = store.submission { return true }; return false }
        XCTAssertTrue(settled)
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.draftText, "preserved")
    }

    // 1. testEmptyDraftCannotSend
    @MainActor func testEmptyDraftCannotSend() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("")
        XCTAssertFalse(store.canSend)
        store.send()
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.submission, .idle)
    }

    // 2. testWhitespaceDraftCannotSend
    @MainActor func testWhitespaceDraftCannotSend() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("   \n  ")
        XCTAssertFalse(store.canSend)
        store.send()
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.submission, .idle)
    }

    // 3. testNotReadyContextCannotSend
    @MainActor func testNotReadyContextCannotSend() async {
        let box = ComposerContextBox(Self.readyContext(isReady: false))
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        XCTAssertFalse(store.canSend, "Stale/unconfirmed agent/model readiness must disable sending")
        store.send()
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.submission, .idle)
        XCTAssertNotNil(store.statusMessage)
    }

    // 4. testMissingSessionDirectoryConnectionCannotSend
    @MainActor func testMissingSessionDirectoryConnectionCannotSend() async {
        let variants: [ComposerContext] = [
            Self.readyContext(session: nil),
            Self.readyContext(directory: nil),
            Self.readyContext(generation: nil),
        ]
        for context in variants {
            let box = ComposerContextBox(context)
            let recorder = ComposerSendRecorder()
            let store = makeStore(box: box, send: { request in
                await recorder.append(request)
                return ComposerStoreTests.admitted(for: request)
            })
            store.editText("hello")
            XCTAssertFalse(store.canSend)
            store.send()
            await settle()
            let count = await recorder.count()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(store.submission, .idle)
            XCTAssertNotNil(store.statusMessage)
        }
    }

    // MARK: Dispatch and admission

    // 5. testRepeatSendSuppressedWhileSending
    @MainActor func testRepeatSendSuppressedWhileSending() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let gate = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            await gate.enter()
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        XCTAssertTrue(store.canSend)
        store.send()
        await gate.waitUntilEntered()
        XCTAssertFalse(store.canSend, "Repeat clicks must be suppressed while sending")
        store.send()
        store.send()
        let firstID = await recorder.firstMessageID()
        XCTAssertNotNil(firstID)
        await gate.releaseAndWait()
        let settled = await waitUntil { store.submission == .idle }
        XCTAssertTrue(settled)
        let count = await recorder.count()
        XCTAssertEqual(count, 1, "Exactly one dispatch per attempt: no retry, no duplicate")
        XCTAssertEqual(store.draftText, "", "Unchanged draft clears on validated admission")
    }

    // 6. testAdmittedClearsUnchangedDraft
    @MainActor func testAdmittedClearsUnchangedDraft() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        store.send()
        let settled = await waitUntil { store.submission == .idle }
        XCTAssertTrue(settled)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
        let requests = await recorder.requests()
        guard let sent = requests.first else {
            XCTFail("Expected exactly one dispatched prompt")
            return
        }
        XCTAssertEqual(sent.text, "hello")
        XCTAssertTrue(sent.messageID.hasPrefix("msg_"))
        XCTAssertEqual(sent.sessionID, SessionID(rawValue: "ses-A"))
        XCTAssertEqual(store.draftText, "")
    }

    // 7. testEditedDraftRetainedOnAdmission
    @MainActor func testEditedDraftRetainedOnAdmission() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let gate = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            await gate.enter()
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        store.send()
        await gate.waitUntilEntered()
        store.editText("hello edited")
        await gate.releaseAndWait()
        let settled = await waitUntil { store.submission == .idle }
        XCTAssertTrue(settled)
        XCTAssertEqual(store.draftText, "hello edited", "Edits during a send must survive admission")
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    // MARK: Rejection and retry

    // 8. testDeclaredRejectionRetainsTextAndAllowsRetry
    @MainActor func testDeclaredRejectionRetainsTextAndAllowsRetry() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return .rejected(.notFound)
        })
        store.editText("hello")
        store.send()
        let rejected = await waitUntil { if case .rejected = store.submission { return true }; return false }
        XCTAssertTrue(rejected)
        if case .rejected(_, _, let problem) = store.submission {
            XCTAssertEqual(problem, .notFound)
        } else {
            XCTFail("Expected rejected, got idle or another state")
        }
        XCTAssertEqual(store.draftText, "hello", "Rejection must retain the text")
        XCTAssertTrue(store.canSend, "Declared rejection must allow explicit retry")
        XCTAssertTrue(store.showsRetry)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    // 9. testRetryAfterRejectionUsesNewIdentity
    @MainActor func testRetryAfterRejectionUsesNewIdentity() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            let n = await recorder.count()
            if n == 1 { return .rejected(.conflict) }
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        store.send()
        let rejected = await waitUntil { store.showsRetry }
        XCTAssertTrue(rejected)
        let firstID = await recorder.firstMessageID()
        let retried = store.retry()
        XCTAssertTrue(retried)
        let admitted = await waitUntil { store.submission == .idle }
        XCTAssertTrue(admitted)
        let count = await recorder.count()
        XCTAssertEqual(count, 2)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        let secondID = requests.last?.messageID
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID, "Explicit retry must use a new message identity")
        XCTAssertEqual(store.draftText, "", "Retry admission clears the unchanged draft")
    }

    // MARK: Unknown outcomes

    // 10. testUnknownRetainsAndBlocksResubmit
    @MainActor func testUnknownRetainsAndBlocksResubmit() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return .unknown(.backend(statusCode: 500))
        })
        store.editText("hello")
        store.send()
        let unknown = await waitUntil { if case .unknown = store.submission { return true }; return false }
        XCTAssertTrue(unknown)
        if case .unknown(_, _, let problem) = store.submission {
            XCTAssertEqual(problem, .backend(statusCode: 500))
        } else {
            XCTFail("Expected unknown, got another state")
        }
        XCTAssertEqual(store.draftText, "hello", "Unknown must retain the original text")
        XCTAssertFalse(store.canSend, "Unknown must block resubmission until an R12 check/disposition")
        XCTAssertFalse(store.showsRetry)
        store.send()
        let retried = store.retry()
        XCTAssertFalse(retried)
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 1, "No automatic or manual resend while unknown")
        XCTAssertNotNil(store.statusMessage)
    }

    // 11. testMismatchedAdmissionIsUnknown
    @MainActor func testMismatchedAdmissionIsUnknown() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            let wrong = PromptAdmittedMessage(
                id: request.messageID,
                sessionID: request.sessionID.rawValue,
                type: "user",
                time: PromptInboxTime(created: 1_700_000_000_000),
                payload: PromptInboxPayload(text: "different text"),
                delivery: .steer
            )
            return .admitted(wrong)
        })
        store.editText("hello")
        store.send()
        let unknown = await waitUntil { if case .unknown = store.submission { return true }; return false }
        XCTAssertTrue(unknown)
        if case .unknown = store.submission {
            // Expected: mismatched success stays ambiguous.
        } else {
            XCTFail("A text-mismatched success must stay unknown")
        }
        XCTAssertEqual(store.draftText, "hello")
        XCTAssertFalse(store.canSend)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    // 12. testCancellationIsUnknown
    @MainActor func testCancellationIsUnknown() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            throw CancellationError()
        })
        store.editText("hello")
        store.send()
        let unknown = await waitUntil { if case .unknown = store.submission { return true }; return false }
        XCTAssertTrue(unknown)
        if case .unknown(_, _, let problem) = store.submission {
            XCTAssertEqual(problem, .requestFailed)
        } else {
            XCTFail("Post-dispatch cancellation must stay unknown, never prove rejection")
        }
        XCTAssertEqual(store.draftText, "hello")
        XCTAssertFalse(store.canSend)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
    }

    // 13. testConnectionReplacementMarksSendingUnknown
    @MainActor func testConnectionReplacementMarksSendingUnknown() async {
        let box = ComposerContextBox(Self.readyContext(generation: 7))
        let recorder = ComposerSendRecorder()
        let gate = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            await gate.enter()
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        store.send()
        await gate.waitUntilEntered()
        box.context = Self.readyContext(generation: 8)
        store.refreshContext()
        let unknown = await waitUntil { store.submission != .idle }
        XCTAssertTrue(unknown)
        if case .unknown = store.submission {
            // Expected: replaced connection converts the attempt to unknown.
        } else {
            XCTFail("A replaced connection must convert the attempt to unknown")
        }
        XCTAssertEqual(store.draftText, "hello", "Original text and context are preserved")
        await gate.releaseAndWait()
        await settle()
        // The late reply on the old connection must not clear or resend.
        if case .unknown = store.submission {
            // Still unknown: no adoption, no auto-resend.
        } else {
            XCTFail("Late old-connection reply must not resolve the unknown attempt")
        }
        XCTAssertEqual(store.draftText, "hello")
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
        XCTAssertFalse(store.canSend)
    }

    // MARK: Session isolation

    // 14. testSessionSwitchIsolatesDraftsAndKeepsAUnknown
    @MainActor func testSessionSwitchIsolatesDraftsAndKeepsAUnknown() async {
        let box = ComposerContextBox(Self.readyContext(session: "ses-A", generation: 7))
        let recorder = ComposerSendRecorder()
        let gate = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            if request.sessionID == SessionID(rawValue: "ses-A") {
                await gate.enter()
            }
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("text for A")
        store.send()
        await gate.waitUntilEntered()
        // Switch to B: A's pending attempt stays reachable, B starts clean.
        box.context = Self.readyContext(session: "ses-B", generation: 7)
        store.refreshContext()
        XCTAssertEqual(store.draftText, "", "Session B must not inherit session A's draft")
        XCTAssertEqual(store.submission, .idle)
        store.editText("text for B")
        // Connection is replaced while viewing B: A's in-flight attempt turns
        // unknown without touching B's draft or submission.
        box.context = Self.readyContext(session: "ses-B", generation: 8)
        store.refreshContext()
        XCTAssertEqual(store.draftText, "text for B")
        XCTAssertEqual(store.submission, .idle)
        XCTAssertTrue(store.canSend)
        // Back to A: the original attempt is unknown with its text retained,
        // and A's would-be success on the old connection is not adopted.
        box.context = Self.readyContext(session: "ses-A", generation: 8)
        store.refreshContext()
        XCTAssertEqual(store.draftText, "text for A")
        if case .unknown = store.submission {
            // Expected: A retained as unknown across the switch.
        } else {
            XCTFail("Session A's replaced-connection attempt must be retained as unknown")
        }
        await gate.releaseAndWait()
        await settle()
        box.context = Self.readyContext(session: "ses-A", generation: 8)
        store.refreshContext()
        XCTAssertEqual(store.draftText, "text for A", "A's late reply must not be adopted anywhere")
        if case .unknown = store.submission {
            // Still unknown after the late reply.
        } else {
            XCTFail("A's late reply must not resolve the unknown attempt")
        }
        // B's draft is still isolated and intact.
        box.context = Self.readyContext(session: "ses-B", generation: 8)
        store.refreshContext()
        XCTAssertEqual(store.draftText, "text for B")
        XCTAssertEqual(store.submission, .idle)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1, "No auto-resend on switch, reconnect, or remount")
        guard let only = requests.first else {
            XCTFail("Expected the original session-A dispatch to be recorded")
            return
        }
        XCTAssertEqual(only.sessionID, SessionID(rawValue: "ses-A"))
    }

    // 15. testStaleReadinessDisablesSendButPreservesDraft
    @MainActor func testStaleReadinessDisablesSendButPreservesDraft() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        XCTAssertTrue(store.canSend)
        box.context = Self.readyContext(isReady: false)
        store.refreshContext()
        XCTAssertFalse(store.canSend, "Stale readiness must disable sending")
        XCTAssertEqual(store.draftText, "hello", "Readiness changes must not discard the draft")
        store.send()
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
    }

    // 16. testStalePublishedReadinessNoDispatchWithoutExplicitRefresh
    @MainActor func testStalePublishedReadinessNoDispatchWithoutExplicitRefresh() async {
        let box = ComposerContextBox(Self.readyContext())
        let recorder = ComposerSendRecorder()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            return ComposerStoreTests.admitted(for: request)
        })
        store.editText("hello")
        let initiallySendable = store.canSend
        XCTAssertTrue(initiallySendable)
        // Selection/connection goes stale while the queued `bind` refresh has
        // not run yet: the published context still looks ready. `send()` must
        // synchronously refresh before `canSend`, so no dispatch happens even
        // though the caller never invoked `refreshContext()`.
        box.context = Self.readyContext(isReady: false)
        store.send()
        await settle()
        let count = await recorder.count()
        XCTAssertEqual(count, 0, "Stale published readiness must not dispatch")
        XCTAssertEqual(store.draftText, "hello", "Never-sent intent must retain the draft")
        let sendableAfter = store.canSend
        XCTAssertFalse(sendableAfter)
        XCTAssertNotNil(store.statusMessage)
        let submissionAfter = store.submission
        XCTAssertEqual(submissionAfter, .idle, "Never-sent intent must not become unknown")
    }

    // 17. testBothSessionsInFlightACompletesFirst
    @MainActor func testBothSessionsInFlightACompletesFirst() async {
        let box = ComposerContextBox(Self.readyContext(session: "ses-A", generation: 7))
        let recorder = ComposerSendRecorder()
        let gateA = ComposerGate()
        let gateB = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            if request.sessionID == SessionID(rawValue: "ses-A") {
                await gateA.enter()
                return ComposerStoreTests.admitted(for: request)
            }
            await gateB.enter()
            return .unknown(.backend(statusCode: 500))
        })
        store.editText("text for A")
        store.send()
        await gateA.waitUntilEntered()
        box.context = Self.readyContext(session: "ses-B", generation: 7)
        store.refreshContext()
        let bInitialSubmission = store.submission
        XCTAssertEqual(bInitialSubmission, .idle)
        XCTAssertEqual(store.draftText, "")
        store.editText("text for B")
        store.send()
        await gateB.waitUntilEntered()
        // Both attempts are in flight on the same connection: B's send must
        // not cancel A's attempt.
        box.context = Self.readyContext(session: "ses-A", generation: 7)
        store.refreshContext()
        let aStillSending: Bool = {
            if case .sending = store.submission { return true }
            return false
        }()
        XCTAssertTrue(aStillSending, "Session A must still be sending after B dispatched")
        await gateA.releaseAndWait()
        let aSettled = await waitUntil { store.submission == .idle }
        XCTAssertTrue(aSettled, "Session A admission must resolve even after B dispatched")
        XCTAssertEqual(store.draftText, "", "A admission clears only A's unchanged draft")
        box.context = Self.readyContext(session: "ses-B", generation: 7)
        store.refreshContext()
        let bStillSending: Bool = {
            if case .sending = store.submission { return true }
            return false
        }()
        XCTAssertTrue(bStillSending, "Session B must still be sending after A admitted")
        XCTAssertEqual(store.draftText, "text for B")
        await gateB.releaseAndWait()
        let bSettled = await waitUntil { store.submission != .idle }
        XCTAssertTrue(bSettled)
        let bState = store.submission
        if case .unknown = bState {
        } else {
            XCTFail("Session B must resolve to unknown with its text retained")
        }
        XCTAssertEqual(store.draftText, "text for B")
        let bSendable = store.canSend
        XCTAssertFalse(bSendable)
        box.context = Self.readyContext(session: "ses-A", generation: 7)
        store.refreshContext()
        let aFinal = store.submission
        XCTAssertEqual(aFinal, .idle)
        XCTAssertEqual(store.draftText, "")
        let count = await recorder.count()
        XCTAssertEqual(count, 2, "Both sessions dispatch independently with no stranded sending")
    }

    // 18. testBothSessionsInFlightBCompletesFirst
    @MainActor func testBothSessionsInFlightBCompletesFirst() async {
        let box = ComposerContextBox(Self.readyContext(session: "ses-A", generation: 7))
        let recorder = ComposerSendRecorder()
        let gateA = ComposerGate()
        let gateB = ComposerGate()
        let store = makeStore(box: box, send: { request in
            await recorder.append(request)
            if request.sessionID == SessionID(rawValue: "ses-A") {
                await gateA.enter()
                return ComposerStoreTests.admitted(for: request)
            }
            await gateB.enter()
            return .unknown(.backend(statusCode: 500))
        })
        store.editText("text for A")
        store.send()
        await gateA.waitUntilEntered()
        box.context = Self.readyContext(session: "ses-B", generation: 7)
        store.refreshContext()
        store.editText("text for B")
        store.send()
        await gateB.waitUntilEntered()
        await gateB.releaseAndWait()
        let bSettled = await waitUntil { store.submission != .idle }
        XCTAssertTrue(bSettled)
        let bState = store.submission
        if case .unknown = bState {
        } else {
            XCTFail("Session B must resolve to unknown with its text retained")
        }
        XCTAssertEqual(store.draftText, "text for B")
        box.context = Self.readyContext(session: "ses-A", generation: 7)
        store.refreshContext()
        let aStillSending: Bool = {
            if case .sending = store.submission { return true }
            return false
        }()
        XCTAssertTrue(aStillSending, "Session A must still be sending after B resolved unknown")
        await gateA.releaseAndWait()
        let aSettled = await waitUntil { store.submission == .idle }
        XCTAssertTrue(aSettled, "Session A admission must resolve after B resolved")
        XCTAssertEqual(store.draftText, "", "A admission clears only A's unchanged draft")
        box.context = Self.readyContext(session: "ses-B", generation: 7)
        store.refreshContext()
        let bFinal = store.submission
        if case .unknown = bFinal {
        } else {
            XCTFail("Session B unknown must be retained after A admitted")
        }
        XCTAssertEqual(store.draftText, "text for B")
        let count = await recorder.count()
        XCTAssertEqual(count, 2, "Both sessions resolve independently in either completion order")
    }
}

// MARK: - Test helpers

@MainActor private final class ComposerContextBox {
    var context: ComposerContext
    init(_ context: ComposerContext) { self.context = context }
}

private actor ComposerSendRecorder {
    private var stored: [PromptRequest] = []
    func append(_ request: PromptRequest) { stored.append(request) }
    func requests() -> [PromptRequest] { stored }
    func count() -> Int { stored.count }
    func firstMessageID() -> String? { stored.first?.messageID }
}

private actor ComposerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func enter() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        entered = false
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func releaseAndWait() async {
        release()
        while entered { await Task.yield() }
    }
}
