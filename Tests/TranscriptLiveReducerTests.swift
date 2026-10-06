import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript live decoder/reducer tests (H06)
//
// Pure, deterministic tests over `SessionTranscriptEventDecoder` and
// `TranscriptLiveReducer`. No I/O, no sleeps, no store wiring. Envelopes are
// built via JSON decoding, mirroring the existing router tests.

final class TranscriptLiveReducerTests: XCTestCase {
    private let session = SessionID(rawValue: "ses-1")

    private enum LiveTestError: Error {
        case expectedEvent(SessionTranscriptDecodeResult)
    }

    // MARK: - Envelope builders

    private func envelope(_ type: String, data: String, created: Double = 1000) throws -> EventEnvelope {
        let json = "{\"id\":\"evt_1\",\"type\":\"\(type)\",\"created\":\(created),\"data\":{\(data)}}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    private func decode(_ type: String, _ data: String, created: Double = 1000) throws -> SessionTranscriptDecodeResult {
        try SessionTranscriptEventDecoder.decode(envelope(type, data: data, created: created))
    }

    private func requireEvent(_ type: String, _ data: String, created: Double = 1000) throws -> SessionTranscriptEvent {
        let result = try decode(type, data, created: created)
        guard case .event(let event) = result else { throw LiveTestError.expectedEvent(result) }
        return event
    }

    private var baseIDs: String { "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\"" }
    private func toolIDs(_ tool: String = "tool_1") -> String { "\(baseIDs),\"id\":\"\(tool)\"" }

    private func stepStartedData(message: String = "msg_1", started: Double = 2000) -> String {
        "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"\(message)\",\"agent\":\"build\"," +
        "\"model\":{\"id\":\"m\",\"providerID\":\"openrouter\"},\"started\":\(started)"
    }

    private func stepEndedData(message: String = "msg_1", finish: String = "stop") -> String {
        "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"\(message)\",\"finish\":\"\(finish)\"," +
        "\"cost\":1.5,\"tokens\":{\"input\":1,\"output\":2}"
    }

    // MARK: - Assistant fixtures

    private func makeAssistant(id: String = "msg_1", created: Double = 2000) -> TranscriptAssistantMessage {
        TranscriptAssistantMessage(
            id: id, created: created, completed: nil, agent: "build",
            model: TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil),
            finish: nil, error: nil, content: []
        )
    }

    private func assistantRow(_ assistant: TranscriptAssistantMessage) -> TranscriptMessage {
        .assistant(assistant)
    }

    private func onlyAssistant(_ messages: [TranscriptMessage]) -> TranscriptAssistantMessage {
        guard messages.count == 1, case .assistant(let assistant) = messages[0] else {
            XCTFail("expected exactly one assistant row")
            return makeAssistant()
        }
        return assistant
    }

    private func apply(
        _ messages: [TranscriptMessage],
        _ event: SessionTranscriptEvent,
        session: SessionID? = nil
    ) -> TranscriptLiveReduction {
        TranscriptLiveReducer.reduce(messages: messages, activeSession: session ?? self.session, event: event)
    }

    private func appliedMessages(
        _ messages: [TranscriptMessage],
        _ event: SessionTranscriptEvent,
        session: SessionID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [TranscriptMessage] {
        let result = apply(messages, event, session: session)
        guard case .applied(let next) = result else {
            XCTFail("expected .applied, got \(String(describing: result))", file: file, line: line)
            throw LiveTestError.expectedEvent(.notApplicable)
        }
        return next
    }

    // MARK: - Decoder: step families

    func testDecoderStepStarted() throws {
        let result = try decode(
            "session.step.started",
            stepStartedData() + ",\"snapshot\":{\"ignored\":true},\"extraField\":[1,2,3]"
        )
        XCTAssertEqual(result, .event(.stepStarted(
            sessionID: session, messageID: "msg_1", agent: "build",
            model: TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil),
            started: 2000, created: 1000
        )))
    }

    func testDecoderStepStartedVariant() throws {
        let result = try decode(
            "session.step.started",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"agent\":\"build\"," +
            "\"model\":{\"id\":\"m\",\"providerID\":\"openrouter\",\"variant\":\"free\"},\"started\":0"
        )
        guard case .event(.stepStarted(_, _, _, let model, _, _)) = result else {
            return XCTFail("expected stepStarted")
        }
        XCTAssertEqual(model.variant, "free")
    }

    func testDecoderStepStartedMalformed() throws {
        let badModels = [
            "\"model\":\"m\"",
            "\"model\":{\"id\":\"m\"}",
            "\"model\":{\"id\":\"m\",\"providerID\":\"openrouter\",\"variant\":7}",
        ]
        for model in badModels {
            let result = try decode(
                "session.step.started",
                "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"agent\":\"build\",\(model),\"started\":2"
            )
            XCTAssertEqual(result, .malformed(sessionID: session, assistantMessageID: "msg_1"), model)
        }
        let badPayloads = [
            "\"assistantMessageID\":\"msg_1\",\"agent\":\"build\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":2",
            "\"sessionID\":\"\",\"assistantMessageID\":\"msg_1\",\"agent\":\"build\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":2",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"\",\"agent\":\"build\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":2",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":2",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"agent\":\"\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":2",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"agent\":\"build\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"}",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"agent\":\"build\",\"model\":{\"id\":\"m\",\"providerID\":\"p\"},\"started\":-1",
        ]
        for payload in badPayloads {
            let result = try decode("session.step.started", payload)
            guard case .malformed = result else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderStepStreamed() throws {
        XCTAssertEqual(
            try decode("session.step.streamed", baseIDs),
            .event(.stepStreamed(sessionID: session, messageID: "msg_1", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.step.streamed", "\"sessionID\":\"ses-1\""),
            .malformed(sessionID: session, assistantMessageID: nil)
        )
    }

    func testDecoderStepEnded() throws {
        XCTAssertEqual(
            try decode("session.step.ended", stepEndedData(), created: 3000),
            .event(.stepEnded(sessionID: session, messageID: "msg_1", finish: "stop", created: 3000))
        )
        for finish in ["stop", "length", "tool-calls", "content-filter", "error", "unknown"] {
            let result = try decode("session.step.ended", stepEndedData(finish: finish))
            guard case .event(.stepEnded(_, _, let decoded, _)) = result, decoded == finish else {
                return XCTFail("expected finish \(finish)")
            }
        }
        let bad = [
            stepEndedData(finish: "done"),
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"cost\":1,\"tokens\":{}",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"finish\":\"stop\",\"tokens\":{}",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"finish\":\"stop\",\"cost\":1",
            "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"msg_1\",\"finish\":7,\"cost\":1,\"tokens\":{}",
        ]
        for payload in bad {
            let result = try decode("session.step.ended", payload)
            guard case .malformed = result else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderStepFailed() throws {
        // Default finish is "error"; an extra `response` field is ignored.
        let result = try decode(
            "session.step.failed",
            "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"boom\",\"response\":{\"body\":\"x\"}}"
        )
        XCTAssertEqual(result, .event(.stepFailed(
            sessionID: session, messageID: "msg_1", finish: "error",
            error: TranscriptToolError(type: "E", message: "boom", status: nil), created: 1000
        )))

        let filtered = try decode(
            "session.step.failed",
            "\(baseIDs),\"finish\":\"content-filter\",\"error\":{\"type\":\"E\",\"message\":\"m\",\"status\":500}"
        )
        guard case .event(.stepFailed(_, _, let finish, let error, _)) = filtered else {
            return XCTFail("expected stepFailed")
        }
        XCTAssertEqual(finish, "content-filter")
        XCTAssertEqual(error.status, 500)

        let bad = [
            "\(baseIDs),\"finish\":\"stop\",\"error\":{\"type\":\"E\",\"message\":\"m\"}",
            "\(baseIDs),\"finish\":7,\"error\":{\"type\":\"E\",\"message\":\"m\"}",
            "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"m\",\"status\":99}",
            "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"m\",\"status\":1.5}",
            "\(baseIDs),\"error\":{\"type\":\"E\"}",
            "\(baseIDs)",
        ]
        for payload in bad {
            let outcome = try decode("session.step.failed", payload)
            guard case .malformed = outcome else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    // MARK: - Decoder: text/reasoning families

    func testDecoderTextAndReasoning() throws {
        XCTAssertEqual(
            try decode("session.text.started", "\(baseIDs),\"ordinal\":0"),
            .event(.textStarted(sessionID: session, messageID: "msg_1", ordinal: 0, created: 1000))
        )
        XCTAssertEqual(
            try decode("session.text.ended", "\(baseIDs),\"ordinal\":2,\"text\":\"hi\",\"state\":{\"ignored\":1}"),
            .event(.textEnded(sessionID: session, messageID: "msg_1", ordinal: 2, text: "hi", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.text.delta", "\(baseIDs),\"ordinal\":2,\"delta\":\"h\""),
            .event(.textDelta(sessionID: session, messageID: "msg_1", ordinal: 2, delta: "h", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.reasoning.started", "\(baseIDs),\"ordinal\":1"),
            .event(.reasoningStarted(sessionID: session, messageID: "msg_1", ordinal: 1, created: 1000))
        )
        XCTAssertEqual(
            try decode("session.reasoning.ended", "\(baseIDs),\"ordinal\":1,\"text\":\"why\""),
            .event(.reasoningEnded(sessionID: session, messageID: "msg_1", ordinal: 1, text: "why", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.reasoning.delta", "\(baseIDs),\"ordinal\":1,\"delta\":\"w\""),
            .event(.reasoningDelta(sessionID: session, messageID: "msg_1", ordinal: 1, delta: "w", created: 1000))
        )
    }

    func testDecoderTextReasoningMalformed() throws {
        let cases: [(String, String)] = [
            ("session.text.started", baseIDs),
            ("session.text.started", "\(baseIDs),\"ordinal\":-1"),
            ("session.text.started", "\(baseIDs),\"ordinal\":1.5"),
            ("session.text.started", "\(baseIDs),\"ordinal\":\"0\""),
            ("session.text.ended", "\(baseIDs),\"ordinal\":0"),
            ("session.text.ended", "\(baseIDs),\"ordinal\":0,\"text\":7"),
            ("session.text.delta", "\(baseIDs),\"ordinal\":0"),
            ("session.text.delta", "\(baseIDs),\"ordinal\":0,\"delta\":7"),
            ("session.reasoning.ended", "\(baseIDs),\"ordinal\":0,\"text\":null"),
            ("session.reasoning.delta", "\(baseIDs),\"delta\":\"x\""),
        ]
        for (type, payload) in cases {
            let result = try decode(type, payload)
            XCTAssertEqual(result, .malformed(sessionID: session, assistantMessageID: "msg_1"), "\(type) \(payload)")
        }
    }

    // MARK: - Decoder: tool families

    func testDecoderToolInput() throws {
        XCTAssertEqual(
            try decode("session.tool.input.started", "\(toolIDs()),\"name\":\"read\""),
            .event(.toolInputStarted(sessionID: session, messageID: "msg_1", toolID: "tool_1", name: "read", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.tool.input.delta", "\(toolIDs()),\"delta\":\"{\\\"a\\\"\""),
            .event(.toolInputDelta(sessionID: session, messageID: "msg_1", toolID: "tool_1", delta: "{\"a\"", created: 1000))
        )
        XCTAssertEqual(
            try decode("session.tool.input.ended", "\(toolIDs()),\"text\":\"{}\""),
            .event(.toolInputEnded(sessionID: session, messageID: "msg_1", toolID: "tool_1", text: "{}", created: 1000))
        )
        let bad: [(String, String)] = [
            ("session.tool.input.started", "\(baseIDs),\"name\":\"read\""),
            ("session.tool.input.started", "\(toolIDs("")),\"name\":\"read\""),
            ("session.tool.input.started", toolIDs()),
            ("session.tool.input.delta", "\(toolIDs()),\"delta\":7"),
            ("session.tool.input.ended", "\(toolIDs()),\"text\":7"),
        ]
        for (type, payload) in bad {
            let result = try decode(type, payload)
            guard case .malformed = result else {
                return XCTFail("expected malformed for \(type) \(payload)")
            }
        }
    }

    func testDecoderToolCalled() throws {
        let result = try decode(
            "session.tool.called",
            "\(toolIDs()),\"input\":{\"path\":\"a\"},\"executed\":true,\"state\":{\"ignored\":1}"
        )
        XCTAssertEqual(result, .event(.toolCalled(
            sessionID: session, messageID: "msg_1", toolID: "tool_1",
            input: .object(["path": .string("a")]), created: 1000
        )))
        let bad = [
            "\(toolIDs()),\"input\":[1],\"executed\":true",
            "\(toolIDs()),\"input\":\"x\",\"executed\":true",
            "\(toolIDs()),\"input\":{},\"executed\":\"yes\"",
            "\(toolIDs()),\"input\":{}",
            "\(toolIDs()),\"executed\":true",
        ]
        for payload in bad {
            let outcome = try decode("session.tool.called", payload)
            guard case .malformed = outcome else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderToolProgress() throws {
        XCTAssertEqual(
            try decode("session.tool.progress", "\(toolIDs()),\"metadata\":{\"pct\":1}"),
            .event(.toolProgress(
                sessionID: session, messageID: "msg_1", toolID: "tool_1",
                metadata: .object(["pct": .number(1)]), created: 1000
            ))
        )
        for payload in ["\(toolIDs())", "\(toolIDs()),\"metadata\":[1]", "\(toolIDs()),\"metadata\":\"x\""] {
            let outcome = try decode("session.tool.progress", payload)
            guard case .malformed = outcome else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderToolSuccess() throws {
        let result = try decode(
            "session.tool.success",
            "\(toolIDs()),\"executed\":false,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]," +
            "\"metadata\":{\"k\":\"v\"},\"resultState\":{\"ignored\":1}"
        )
        XCTAssertEqual(result, .event(.toolSuccess(
            sessionID: session, messageID: "msg_1", toolID: "tool_1",
            content: [.text("ok")], executed: false,
            metadata: .object(["k": .string("v")]), created: 1000
        )))
        let bad = [
            "\(toolIDs()),\"executed\":true,\"content\":[]",
            "\(toolIDs()),\"executed\":true",
            "\(toolIDs()),\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]",
            "\(toolIDs()),\"executed\":7,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"future\",\"text\":\"ok\"}]",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\"}]",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"file\",\"uri\":\"u\"}]",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"metadata\":\"x\"",
        ]
        for payload in bad {
            let outcome = try decode("session.tool.success", payload)
            guard case .malformed = outcome else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderToolFailed() throws {
        let result = try decode(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}," +
            "\"content\":[{\"type\":\"file\",\"uri\":\"u\",\"mime\":\"text/plain\"}],\"metadata\":{}"
        )
        XCTAssertEqual(result, .event(.toolFailed(
            sessionID: session, messageID: "msg_1", toolID: "tool_1",
            error: TranscriptToolError(type: "E", message: "m", status: nil),
            executed: true, content: [.file(uri: "u", mime: "text/plain", name: nil)],
            metadata: .object([:]), created: 1000
        )))
        // Optional content/metadata may be absent.
        let bare = try decode(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":false,\"error\":{\"type\":\"E\",\"message\":\"m\"}"
        )
        guard case .event(.toolFailed(_, _, _, _, _, let content, let metadata, _)) = bare,
              content == nil, metadata == nil else {
            return XCTFail("expected bare toolFailed")
        }
        let bad = [
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"},\"content\":[]",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"},\"metadata\":7",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\"}",
            "\(toolIDs()),\"error\":{\"type\":\"E\",\"message\":\"m\"}",
        ]
        for payload in bad {
            let outcome = try decode("session.tool.failed", payload)
            guard case .malformed = outcome else {
                return XCTFail("expected malformed for \(payload)")
            }
        }
    }

    func testDecoderNotApplicableAndAttribution() throws {
        for type in ["session.deleted", "session.revert.committed", "session.future.thing", "server.connected", "project.updated"] {
            XCTAssertEqual(try decode(type, baseIDs), .notApplicable, type)
        }
        // Recognized type, unusable ids: no attribution to guess from.
        XCTAssertEqual(
            try decode("session.step.started", "\"sessionID\":\"\",\"assistantMessageID\":\"\""),
            .malformed(sessionID: nil, assistantMessageID: nil)
        )
        XCTAssertEqual(
            try decode("session.tool.success", "\"sessionID\":\"\",\"assistantMessageID\":\"msg_1\""),
            .malformed(sessionID: nil, assistantMessageID: "msg_1")
        )
        XCTAssertEqual(
            try decode("session.tool.success", "\"sessionID\":\"ses-1\",\"assistantMessageID\":\"\""),
            .malformed(sessionID: session, assistantMessageID: nil)
        )
        // Non-object data on a recognized type.
        let envelope = try JSONDecoder().decode(
            EventEnvelope.self,
            from: Data("{\"id\":\"evt_1\",\"type\":\"session.step.ended\",\"created\":1,\"data\":[]}".utf8)
        )
        XCTAssertEqual(
            SessionTranscriptEventDecoder.decode(envelope),
            .malformed(sessionID: nil, assistantMessageID: nil)
        )
    }

    // MARK: - Reducer: steps

    func testStepStartedAppendsAssistant() throws {
        let event = try requireEvent("session.step.started", stepStartedData(), created: 1500)
        let next = try appliedMessages([], event)
        let assistant = onlyAssistant(next)
        XCTAssertEqual(assistant.id, "msg_1")
        XCTAssertEqual(assistant.created, 2000)
        XCTAssertNil(assistant.completed)
        XCTAssertEqual(assistant.agent, "build")
        XCTAssertEqual(assistant.model, TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil))
        XCTAssertNil(assistant.finish)
        XCTAssertNil(assistant.error)
        XCTAssertEqual(assistant.content, [])
    }

    func testStepStartedDuplicateAndDelayedStartIgnored() throws {
        let event = try requireEvent("session.step.started", stepStartedData())
        var messages = try appliedMessages([], event)
        // Duplicate start: ignored, projection identical.
        XCTAssertEqual(apply(messages, event), .ignored)
        // Delayed start after terminal: never regresses.
        let ended = try requireEvent("session.step.ended", stepEndedData(), created: 3000)
        messages = try appliedMessages(messages, ended)
        XCTAssertEqual(apply(messages, event), .ignored)
        let assistant = onlyAssistant(messages)
        XCTAssertEqual(assistant.completed, 3000)
        XCTAssertEqual(assistant.finish, "stop")
    }

    func testStepEndedAppliesAndIsIdempotent() throws {
        let started = try requireEvent("session.step.started", stepStartedData())
        var messages = try appliedMessages([], started)
        let ended = try requireEvent("session.step.ended", stepEndedData(), created: 3000)
        messages = try appliedMessages(messages, ended)
        let assistant = onlyAssistant(messages)
        XCTAssertEqual(assistant.completed, 3000)
        XCTAssertEqual(assistant.finish, "stop")
        XCTAssertNil(assistant.error)
        // Duplicate terminal: ignored with an identical projection.
        let before = messages
        XCTAssertEqual(apply(messages, ended), .ignored)
        XCTAssertEqual(messages, before)
        // A different terminal (failed) after ended: ignored, never overwritten.
        let failed = try requireEvent(
            "session.step.failed",
            "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"m\"}"
        )
        XCTAssertEqual(apply(messages, failed), .ignored)
        XCTAssertEqual(messages, before)
    }

    func testTerminalBeforeStartRequestsRefreshThenStartApplies() throws {
        let ended = try requireEvent("session.step.ended", stepEndedData())
        XCTAssertEqual(apply([], ended), .needsMessageRefresh(messageID: "msg_1"))
        let started = try requireEvent("session.step.started", stepStartedData())
        let messages = try appliedMessages([], started)
        XCTAssertNil(onlyAssistant(messages).completed)
    }

    func testStepFailedFinishes() throws {
        let started = try requireEvent("session.step.started", stepStartedData())
        var messages = try appliedMessages([], started)
        let failed = try requireEvent(
            "session.step.failed",
            "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"boom\",\"status\":400}",
            created: 3000
        )
        messages = try appliedMessages(messages, failed)
        let assistant = onlyAssistant(messages)
        XCTAssertEqual(assistant.completed, 3000)
        XCTAssertEqual(assistant.finish, "error")
        XCTAssertEqual(assistant.error, TranscriptToolError(type: "E", message: "boom", status: 400))
        XCTAssertEqual(apply(messages, failed), .ignored)

        var other = try appliedMessages([], started)
        let filtered = try requireEvent(
            "session.step.failed",
            "\(baseIDs),\"finish\":\"content-filter\",\"error\":{\"type\":\"E\",\"message\":\"m\"}"
        )
        other = try appliedMessages(other, filtered)
        XCTAssertEqual(onlyAssistant(other).finish, "content-filter")
    }

    func testStepTerminalMissingAssistant() throws {
        let ended = try requireEvent("session.step.ended", stepEndedData())
        XCTAssertEqual(
            apply([.user(TranscriptTextMessage(id: "u1", created: 1, text: "hi"))], ended),
            .needsMessageRefresh(messageID: "msg_1")
        )
        // The id belongs to a non-assistant (opaque) row: reconcile, do not reinterpret.
        let opaque = TranscriptMessage.opaque(TranscriptOpaqueMessage(
            id: "msg_1", kind: "assistant", raw: .object(["id": .string("msg_1")])
        ))
        XCTAssertEqual(apply([opaque], ended), .needsMessageRefresh(messageID: "msg_1"))
        // A non-assistant row with the same id does not block step.started from
        // creating the assistant, but the collision still reconciles first.
        let started = try requireEvent("session.step.started", stepStartedData())
        XCTAssertEqual(apply([opaque], started), .needsMessageRefresh(messageID: "msg_1"))
    }

    // MARK: - Reducer: tool lifecycle

    private func successLifecycle() throws -> [TranscriptMessage] {
        var messages: [TranscriptMessage] = []
        messages = try appliedMessages(messages, requireEvent(
            "session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\"", created: 2100))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"{\\\"path\\\":\\\"a\\\"}\""))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{\"path\":\"a\"},\"executed\":true"))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"metadata\":{\"k\":\"v\"}"))
        return messages
    }

    func testCompleteToolLifecycleSuccess() throws {
        var messages: [TranscriptMessage] = []
        messages = try appliedMessages(messages, requireEvent(
            "session.step.started", stepStartedData()))
        XCTAssertEqual(onlyAssistant(messages).content.count, 0)

        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\"", created: 2100))
        guard case .tool(let streaming) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(streaming.id, "tool_1")
        XCTAssertEqual(streaming.name, "read")
        XCTAssertEqual(streaming.created, 2100)
        XCTAssertEqual(streaming.state, .streaming(input: ""))

        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"{}\""))
        guard case .tool(let ended) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(ended.state, .streaming(input: "{}"))

        messages = try appliedMessages(messages, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{\"path\":\"a\"},\"executed\":true"))
        guard case .tool(let running) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(running.state, .running(input: .object(["path": .string("a")]), metadata: .object([:])))
        // Creation time survives transitions.
        XCTAssertEqual(running.created, 2100)

        messages = try appliedMessages(messages, requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"metadata\":{\"k\":\"v\"}"))
        guard case .tool(let done) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(done.state, .completed(
            input: .object(["path": .string("a")]),
            content: [.text("ok")],
            metadata: .object(["k": .string("v")])
        ))
    }

    func testCompleteToolLifecycleFailedFromRunning() throws {
        var messages: [TranscriptMessage] = []
        messages = try appliedMessages(messages, requireEvent(
            "session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{\"path\":\"a\"},\"executed\":false"))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":false,\"error\":{\"type\":\"E\",\"message\":\"m\"}," +
            "\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]"))
        guard case .tool(let failed) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(failed.state, .error(
            input: .object(["path": .string("a")]),
            error: TranscriptToolError(type: "E", message: "m", status: nil),
            content: [.text("partial")],
            metadata: nil
        ))
    }

    func testToolFailedFromStreamingKeepsEmptyInput() throws {
        var messages: [TranscriptMessage] = []
        messages = try appliedMessages(messages, requireEvent(
            "session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        // `called` was never observed: the input object is unknown, so the
        // error row carries an empty object rather than fabricated input.
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}"))
        guard case .tool(let failed) = onlyAssistant(messages).content.first else {
            return XCTFail("expected tool row")
        }
        XCTAssertEqual(failed.state, .error(
            input: .object([:]),
            error: TranscriptToolError(type: "E", message: "m", status: nil),
            content: nil,
            metadata: nil
        ))
    }

    func testDuplicateLifecycleIsIdempotent() throws {
        let sequence = [
            try requireEvent("session.step.started", stepStartedData()),
            try requireEvent("session.tool.input.started", "\(toolIDs()),\"name\":\"read\""),
            try requireEvent("session.tool.input.ended", "\(toolIDs()),\"text\":\"{}\""),
            try requireEvent("session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"),
            try requireEvent(
                "session.tool.success",
                "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]"),
            try requireEvent("session.step.ended", stepEndedData()),
        ]
        var messages: [TranscriptMessage] = []
        for event in sequence {
            messages = try appliedMessages(messages, event)
        }
        let settled = messages
        // Reducing the same events again yields .ignored or an identical
        // projection; the final projection is unchanged.
        for event in sequence {
            let result = apply(messages, event)
            switch result {
            case .ignored:
                break
            case .applied(let next):
                XCTAssertEqual(next, messages)
                messages = next
            default:
                XCTFail("duplicate must not reconcile: \(String(describing: result))")
            }
        }
        XCTAssertEqual(messages, settled)
    }

    func testTerminalToolNeverRegresses() throws {
        let messages = try successLifecycle()
        let before = messages
        let replay = [
            try requireEvent("session.tool.input.started", "\(toolIDs()),\"name\":\"read\""),
            try requireEvent("session.tool.input.ended", "\(toolIDs()),\"text\":\"late\""),
            try requireEvent("session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"),
            try requireEvent(
                "session.tool.success",
                "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"late\"}]"),
            try requireEvent(
                "session.tool.failed",
                "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}"),
        ]
        for event in replay {
            XCTAssertEqual(apply(messages, event), .ignored, String(describing: event))
        }
        XCTAssertEqual(messages, before)

        // Same for the error terminal.
        var failed: [TranscriptMessage] = []
        failed = try appliedMessages(failed, requireEvent("session.step.started", stepStartedData()))
        failed = try appliedMessages(failed, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        failed = try appliedMessages(failed, requireEvent(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}"))
        let failedBefore = failed
        XCTAssertEqual(try apply(failed, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true")), .ignored)
        XCTAssertEqual(try apply(failed, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"late\"")), .ignored)
        XCTAssertEqual(try apply(failed, requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"late\"}]")), .ignored)
        XCTAssertEqual(failed, failedBefore)
    }

    func testToolCalledWithoutStartNeedsRefresh() throws {
        var messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        // `called` for an unknown tool: the name is unknown, so reconcile.
        XCTAssertEqual(try apply(messages, requireEvent(
            "session.tool.called", toolIDs("tool_9") + ",\"input\":{},\"executed\":true")),
            .needsMessageRefresh(messageID: "msg_1"))
        // `success` while still streaming (called not observed): input unknown.
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        XCTAssertEqual(try apply(messages, requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]")),
            .needsMessageRefresh(messageID: "msg_1"))
        // Missing assistant entirely.
        XCTAssertEqual(try apply([], requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\"")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply([], requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"x\"")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply([], requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply([], requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"x\"}]")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply([], requireEvent(
            "session.tool.failed",
            "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}")),
            .needsMessageRefresh(messageID: "msg_1"))
        // Unknown tool on an existing assistant.
        for type in ["session.tool.input.ended", "session.tool.called", "session.tool.success", "session.tool.failed"] {
            let payload: String
            switch type {
            case "session.tool.input.ended": payload = toolIDs("tool_9") + ",\"text\":\"x\""
            case "session.tool.called": payload = toolIDs("tool_9") + ",\"input\":{},\"executed\":true"
            case "session.tool.success":
                payload = toolIDs("tool_9") + ",\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"x\"}]"
            default:
                payload = toolIDs("tool_9") + ",\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}"
            }
            XCTAssertEqual(
                apply(messages, try requireEvent(type, payload)),
                .needsMessageRefresh(messageID: "msg_1"), type)
        }
    }

    func testToolInputEndedOnlyUpdatesStreaming() throws {
        var messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        // Same text again: identical result.
        let once = try appliedMessages(messages, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"abc\""))
        let twice = try appliedMessages(messages, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"abc\""))
        XCTAssertEqual(once, twice)
        // After `called`, a late input.ended is ignored, never regressed.
        let running = try appliedMessages(once, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"))
        XCTAssertEqual(try apply(running, requireEvent(
            "session.tool.input.ended", "\(toolIDs()),\"text\":\"late\"")), .ignored)
        // A repeated `called` while running is ignored.
        XCTAssertEqual(try apply(running, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{\"other\":1},\"executed\":true")), .ignored)
    }

    func testMultipleToolsLeaveSiblingsUnchanged() throws {
        var messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        let user = TranscriptMessage.user(TranscriptTextMessage(id: "u1", created: 1, text: "hi"))
        messages = [user] + messages
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", toolIDs("tool_a") + ",\"name\":\"read\""))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", toolIDs("tool_b") + ",\"name\":\"bash\""))
        let before = messages
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.ended", toolIDs("tool_b") + ",\"text\":\"ls\""))
        // The user row and tool_a are byte-identical; only tool_b changed.
        XCTAssertEqual(messages[0], before[0])
        guard case .assistant(let afterAssistant) = messages[1],
              case .assistant(let beforeAssistant) = before[1] else {
            return XCTFail("expected assistants")
        }
        XCTAssertEqual(afterAssistant.content.count, 2)
        XCTAssertEqual(afterAssistant.content[0], beforeAssistant.content[0])
        guard case .tool(let toolB) = afterAssistant.content[1] else {
            return XCTFail("expected tool_b")
        }
        XCTAssertEqual(toolB.id, "tool_b")
        XCTAssertEqual(toolB.state, .streaming(input: "ls"))
    }

    func testLargeTextAndFileToolOutput() throws {
        let big = String(repeating: "x", count: 1_000_000)
        var messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"))
        // Building the envelope through JSON keeps escaping honest.
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessionID": "ses-1", "assistantMessageID": "msg_1", "id": "tool_1",
            "executed": true,
            "content": [
                ["type": "text", "text": big],
                ["type": "file", "uri": "file:///tmp/out.png", "mime": "image/png", "name": "out.png"],
                ["type": "file", "uri": "file:///tmp/plain.bin", "mime": "application/octet-stream"],
            ],
        ])
        let payloadString = String(decoding: payload, as: UTF8.self)
        let json = "{\"id\":\"evt_1\",\"type\":\"session.tool.success\",\"created\":1000,\"data\":\(payloadString)}"
        let envelope = try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
        let decoded = SessionTranscriptEventDecoder.decode(envelope)
        guard case .event(let event) = decoded else {
            return XCTFail("expected large tool.success to decode")
        }
        messages = try appliedMessages(messages, event)
        guard case .tool(let tool) = onlyAssistant(messages).content.first,
              case .completed(_, let content, _) = tool.state else {
            return XCTFail("expected completed tool")
        }
        XCTAssertEqual(content, [
            .text(big),
            .file(uri: "file:///tmp/out.png", mime: "image/png", name: "out.png"),
            .file(uri: "file:///tmp/plain.bin", mime: "application/octet-stream", name: nil),
        ])
    }

    func testBadEventDoesNotCorruptValidNeighbors() throws {
        var messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        let before = messages
        // A malformed recognized event reconciles without mutating.
        let malformed = try decode(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[]")
        guard case .malformed(_, let id) = malformed, id == "msg_1" else {
            return XCTFail("expected malformed with attribution")
        }
        let convenience = TranscriptLiveReducer.reduce(
            messages: messages, activeSession: session, decoded: malformed)
        XCTAssertEqual(convenience, .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(messages, before)
        // Valid neighbors still apply afterwards.
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"))
        messages = try appliedMessages(messages, requireEvent(
            "session.tool.success",
            "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]"))
        guard case .tool(let tool) = onlyAssistant(messages).content.first,
              case .completed = tool.state else {
            return XCTFail("expected completed tool")
        }
    }

    // MARK: - Reducer: ephemeral and session gating

    func testTextReasoningEndedRequestRefresh() throws {
        let messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        // The projector's "latest text" target cannot be reproduced from the
        // ordinal, so ended boundaries reconcile even when present.
        XCTAssertEqual(try apply(messages, requireEvent(
            "session.text.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"hi\"")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply(messages, requireEvent(
            "session.reasoning.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"why\"")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(try apply([], requireEvent(
            "session.text.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"hi\"")),
            .needsMessageRefresh(messageID: "msg_1"))
    }

    func testEphemeralEventsAreIgnoredUnchanged() throws {
        let messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        let events = [
            try requireEvent("session.step.streamed", baseIDs),
            try requireEvent("session.text.started", "\(baseIDs),\"ordinal\":0"),
            try requireEvent("session.text.delta", "\(baseIDs),\"ordinal\":0,\"delta\":\"h\""),
            try requireEvent("session.reasoning.started", "\(baseIDs),\"ordinal\":0"),
            try requireEvent("session.reasoning.delta", "\(baseIDs),\"ordinal\":0,\"delta\":\"w\""),
            try requireEvent("session.tool.input.delta", "\(toolIDs()),\"delta\":\"{\""),
        ]
        var withTool = try appliedMessages(messages, requireEvent(
            "session.tool.input.started", "\(toolIDs()),\"name\":\"read\""))
        withTool = try appliedMessages(withTool, requireEvent(
            "session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"))
        var progressEvents = events
        progressEvents.append(try requireEvent(
            "session.tool.progress", "\(toolIDs()),\"metadata\":{}"))
        for event in progressEvents {
            let result = apply(withTool, event)
            XCTAssertEqual(result, .ignored, String(describing: event))
        }
        // The durable rows are untouched by the ephemeral burst.
        guard case .tool(let tool) = onlyAssistant(withTool).content.first,
              case .running = tool.state else {
            return XCTFail("expected running tool after ephemeral burst")
        }
    }

    func testWrongSessionIsIgnored() throws {
        let empty: [TranscriptMessage] = []
        let foreignPayloads = [
            ("session.step.started", stepStartedData()),
            ("session.step.ended", stepEndedData()),
            ("session.tool.input.started", "\(toolIDs()),\"name\":\"read\""),
            ("session.tool.success",
                "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"x\"}]"),
            ("session.text.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"hi\""),
        ]
        for (type, payload) in foreignPayloads {
            let foreign = try requireEvent(
                type, payload.replacingOccurrences(of: "ses-1", with: "ses-other"))
            XCTAssertEqual(apply(empty, foreign), .ignored, type)
            // Sanity: the same shape applies when its session is active.
            let own = try requireEvent(type, payload)
            let result = TranscriptLiveReducer.reduce(
                messages: empty, activeSession: session, decoded: .event(own))
            switch (type, result) {
            case ("session.text.ended", .needsMessageRefresh(let id)):
                XCTAssertEqual(id, "msg_1")
            case (_, .applied), (_, .needsMessageRefresh):
                break
            default:
                XCTFail("unexpected result for \(type): \(String(describing: result))")
            }
        }
    }

    func testOnlyTargetedMessageChanges() throws {
        var messages = try appliedMessages([], requireEvent(
            "session.step.started", stepStartedData(message: "msg_a", started: 100)))
        messages = try appliedMessages(messages, requireEvent(
            "session.step.started", stepStartedData(message: "msg_b", started: 200)))
        let before = messages
        let ended = try requireEvent(
            "session.step.ended",
            stepEndedData(message: "msg_b"), created: 300)
        let next = try appliedMessages(messages, ended)
        XCTAssertEqual(next.count, before.count)
        XCTAssertEqual(next[0], before[0])
        guard case .assistant(let updated) = next[1] else {
            return XCTFail("expected assistant")
        }
        XCTAssertEqual(updated.id, "msg_b")
        XCTAssertEqual(updated.completed, 300)
    }

    func testDecodeResultConvenience() throws {
        let messages = try appliedMessages([], requireEvent("session.step.started", stepStartedData()))
        // Well-formed events delegate to the typed reducer.
        let ended = try decode("session.step.ended", stepEndedData(), created: 3000)
        let result = TranscriptLiveReducer.reduce(messages: messages, activeSession: session, decoded: ended)
        guard case .applied(let next) = result else {
            return XCTFail("expected applied")
        }
        XCTAssertEqual(onlyAssistant(next).completed, 3000)
        // Unknown types stay quiet.
        XCTAssertEqual(
            TranscriptLiveReducer.reduce(messages: messages, activeSession: session, decoded: .notApplicable),
            .ignored)
        // Malformed with a usable id targets that message; otherwise full refresh.
        XCTAssertEqual(
            TranscriptLiveReducer.reduce(
                messages: messages, activeSession: session,
                decoded: .malformed(sessionID: session, assistantMessageID: "msg_1")),
            .needsMessageRefresh(messageID: "msg_1"))
        XCTAssertEqual(
            TranscriptLiveReducer.reduce(
                messages: messages, activeSession: session,
                decoded: .malformed(sessionID: session, assistantMessageID: nil)),
            .needsFullRefresh(.malformedEvent))
        XCTAssertEqual(
            TranscriptLiveReducer.reduce(
                messages: messages, activeSession: session,
                decoded: .malformed(sessionID: nil, assistantMessageID: nil)),
            .needsFullRefresh(.malformedEvent))
    }

    // MARK: - Router: structural classifier

    func testStructuralRouteIgnoresCoveredFamilies() throws {
        let payloads: [(String, String)] = [
            ("session.step.started", stepStartedData()),
            ("session.step.streamed", baseIDs),
            ("session.step.ended", stepEndedData()),
            ("session.step.failed", "\(baseIDs),\"error\":{\"type\":\"E\",\"message\":\"m\"}"),
            ("session.text.started", "\(baseIDs),\"ordinal\":0"),
            ("session.text.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"hi\""),
            ("session.text.delta", "\(baseIDs),\"ordinal\":0,\"delta\":\"h\""),
            ("session.reasoning.started", "\(baseIDs),\"ordinal\":0"),
            ("session.reasoning.ended", "\(baseIDs),\"ordinal\":0,\"text\":\"why\""),
            ("session.reasoning.delta", "\(baseIDs),\"ordinal\":0,\"delta\":\"w\""),
            ("session.tool.input.started", "\(toolIDs()),\"name\":\"read\""),
            ("session.tool.input.delta", "\(toolIDs()),\"delta\":\"{\""),
            ("session.tool.input.ended", "\(toolIDs()),\"text\":\"{}\""),
            ("session.tool.called", "\(toolIDs()),\"input\":{},\"executed\":true"),
            ("session.tool.progress", "\(toolIDs()),\"metadata\":{}"),
            ("session.tool.success",
                "\(toolIDs()),\"executed\":true,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]"),
            ("session.tool.failed",
                "\(toolIDs()),\"executed\":true,\"error\":{\"type\":\"E\",\"message\":\"m\"}"),
        ]
        XCTAssertEqual(payloads.count, SessionTranscriptEventDecoder.coveredTypes.count)
        for (type, payload) in payloads {
            let route = SessionEventRouter.structuralRoute(try envelope(type, data: payload))
            XCTAssertEqual(route, .ignored, type)
        }
        // Covered families stay ignored even without session attribution.
        for type in SessionTranscriptEventDecoder.coveredTypes {
            let route = SessionEventRouter.structuralRoute(try envelope(type, data: ""))
            XCTAssertEqual(route, .ignored, type)
        }
    }

    func testStructuralRouteDefersToRouteOtherwise() throws {
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(try envelope("session.deleted", data: "\"sessionID\":\"ses-1\"")),
            .sessionDeleted(session))
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(
                try envelope("session.revert.committed", data: "\"sessionID\":\"ses-1\",\"to\":\"msg_1\"")),
            .messagesRemoved(session, boundary: "msg_1"))
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(
                try envelope("session.future.thing", data: "\"sessionID\":\"ses-1\"")),
            .historyChanged(session))
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(
                try envelope("session.shell.started", data: "\"sessionID\":\"ses-1\"")),
            .historyChanged(session))
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(try envelope("session.deleted", data: "")),
            .unroutable)
        XCTAssertEqual(
            SessionEventRouter.structuralRoute(try envelope("server.connected", data: "\"sessionID\":\"ses-1\"")),
            .ignored)
        // `route(_:)` itself is unchanged for covered families.
        XCTAssertEqual(
            SessionEventRouter.route(try envelope("session.step.started", data: "\"sessionID\":\"ses-1\"")),
            .historyChanged(session))
    }

    // MARK: - H08 stream settlement helpers (pure)

    private func settledAssistant(content: [TranscriptContent]) -> [TranscriptMessage] {
        [assistantRow(TranscriptAssistantMessage(
            id: "msg_1", created: 2000, completed: nil, agent: "build",
            model: TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil),
            finish: nil, error: nil, content: content
        ))]
    }

    func testAppendingEmptyContentRequiresAssistantRow() {
        XCTAssertNil(TranscriptLiveReducer.appendingEmptyContent(to: [], messageID: "msg_1", kind: .text))
        let opaque: [TranscriptMessage] = [.opaque(TranscriptOpaqueMessage(id: "msg_1", kind: "x", raw: .null))]
        XCTAssertNil(TranscriptLiveReducer.appendingEmptyContent(to: opaque, messageID: "msg_1", kind: .text))
        let other = settledAssistant(content: [.text("hi")])
        XCTAssertNil(TranscriptLiveReducer.appendingEmptyContent(to: other, messageID: "msg_2", kind: .text))
    }

    func testAppendingEmptyContentAddsTextAtEnd() {
        let tool = TranscriptToolContent(id: "t", name: "read", created: 1, state: .streaming(input: ""))
        let start = settledAssistant(content: [.text("hi"), .tool(tool)])
        let next = TranscriptLiveReducer.appendingEmptyContent(to: start, messageID: "msg_1", kind: .text)
        XCTAssertEqual(onlyAssistant(next ?? []).content, [.text("hi"), .tool(tool), .text("")])
        // The input is untouched.
        XCTAssertEqual(onlyAssistant(start).content, [.text("hi"), .tool(tool)])
    }

    func testAppendingEmptyContentAddsReasoningAtEnd() {
        let start = settledAssistant(content: [.text("hi")])
        let next = TranscriptLiveReducer.appendingEmptyContent(to: start, messageID: "msg_1", kind: .reasoning)
        XCTAssertEqual(onlyAssistant(next ?? []).content, [.text("hi"), .reasoning("")])
    }

    func testSettingLastContentTextRequiresMatchingItem() {
        XCTAssertNil(TranscriptLiveReducer.settingLastContentText(
            in: [], messageID: "msg_1", kind: .text, text: "hi"))
        let toolsOnly = settledAssistant(content: [
            .tool(TranscriptToolContent(id: "t", name: "read", created: 1, state: .streaming(input: ""))),
        ])
        XCTAssertNil(TranscriptLiveReducer.settingLastContentText(
            in: toolsOnly, messageID: "msg_1", kind: .text, text: "hi"))
        XCTAssertNil(TranscriptLiveReducer.settingLastContentText(
            in: toolsOnly, messageID: "msg_1", kind: .reasoning, text: "why"))
    }

    func testSettingLastContentTextTargetsLatestOfKind() {
        let tool = TranscriptToolContent(id: "t", name: "read", created: 1, state: .streaming(input: ""))
        let start = settledAssistant(content: [.text("first"), .tool(tool), .text(""), .reasoning("r")])
        let next = TranscriptLiveReducer.settingLastContentText(
            in: start, messageID: "msg_1", kind: .text, text: "second")
        XCTAssertEqual(
            onlyAssistant(next ?? []).content,
            [.text("first"), .tool(tool), .text("second"), .reasoning("r")])
        let reasoning = TranscriptLiveReducer.settingLastContentText(
            in: start, messageID: "msg_1", kind: .reasoning, text: "why")
        XCTAssertEqual(
            onlyAssistant(reasoning ?? []).content,
            [.text("first"), .tool(tool), .text(""), .reasoning("why")])
    }
}
