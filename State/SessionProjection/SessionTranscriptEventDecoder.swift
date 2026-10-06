/// Pure decoder for the assistant execution path of the pinned OpenCode V2
/// session-event contract.
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`
/// (`packages/schema/src/session-event.ts`,
/// `packages/core/src/session/message-updater.ts`).
///
/// Session attribution uses only `data.sessionID` (non-empty string). The
/// envelope `id` shape (`evt_...`), `location`, `metadata`, and ordering
/// fields (`durable.seq`) are never used for ordering against snapshots.
/// Unknown fields are ignored, never interpreted.
///
/// This decoder performs no I/O, uses no clock, and imports no UI framework.

/// Typed durable/ephemeral facts for the assistant execution path. Every case
/// carries the owning `sessionID` and the envelope `created` (finite ms).
/// Ephemeral cases (deltas, streamed markers, progress, `*.started` slots)
/// decode here so callers can distinguish "recognized" from "unknown", but
/// they are not durable reducer facts.
enum SessionTranscriptEvent: Equatable, Sendable {
    case stepStarted(sessionID: SessionID, messageID: String, agent: String, model: TranscriptModelRef, started: Double, created: Double)
    case stepStreamed(sessionID: SessionID, messageID: String, created: Double)
    case stepEnded(sessionID: SessionID, messageID: String, finish: String, created: Double)
    case stepFailed(sessionID: SessionID, messageID: String, finish: String, error: TranscriptToolError, created: Double)
    case textStarted(sessionID: SessionID, messageID: String, ordinal: Int, created: Double)
    case textEnded(sessionID: SessionID, messageID: String, ordinal: Int, text: String, created: Double)
    case textDelta(sessionID: SessionID, messageID: String, ordinal: Int, delta: String, created: Double)
    case reasoningStarted(sessionID: SessionID, messageID: String, ordinal: Int, created: Double)
    case reasoningEnded(sessionID: SessionID, messageID: String, ordinal: Int, text: String, created: Double)
    case reasoningDelta(sessionID: SessionID, messageID: String, ordinal: Int, delta: String, created: Double)
    case toolInputStarted(sessionID: SessionID, messageID: String, toolID: String, name: String, created: Double)
    case toolInputDelta(sessionID: SessionID, messageID: String, toolID: String, delta: String, created: Double)
    case toolInputEnded(sessionID: SessionID, messageID: String, toolID: String, text: String, created: Double)
    case toolCalled(sessionID: SessionID, messageID: String, toolID: String, input: TranscriptJSONValue, created: Double)
    case toolProgress(sessionID: SessionID, messageID: String, toolID: String, metadata: TranscriptJSONValue, created: Double)
    case toolSuccess(sessionID: SessionID, messageID: String, toolID: String, content: [TranscriptToolOutput], executed: Bool, metadata: TranscriptJSONValue?, created: Double)
    case toolFailed(sessionID: SessionID, messageID: String, toolID: String, error: TranscriptToolError, executed: Bool, content: [TranscriptToolOutput]?, metadata: TranscriptJSONValue?, created: Double)

    var sessionID: SessionID {
        switch self {
        case .stepStarted(let sessionID, _, _, _, _, _): return sessionID
        case .stepStreamed(let sessionID, _, _): return sessionID
        case .stepEnded(let sessionID, _, _, _): return sessionID
        case .stepFailed(let sessionID, _, _, _, _): return sessionID
        case .textStarted(let sessionID, _, _, _): return sessionID
        case .textEnded(let sessionID, _, _, _, _): return sessionID
        case .textDelta(let sessionID, _, _, _, _): return sessionID
        case .reasoningStarted(let sessionID, _, _, _): return sessionID
        case .reasoningEnded(let sessionID, _, _, _, _): return sessionID
        case .reasoningDelta(let sessionID, _, _, _, _): return sessionID
        case .toolInputStarted(let sessionID, _, _, _, _): return sessionID
        case .toolInputDelta(let sessionID, _, _, _, _): return sessionID
        case .toolInputEnded(let sessionID, _, _, _, _): return sessionID
        case .toolCalled(let sessionID, _, _, _, _): return sessionID
        case .toolProgress(let sessionID, _, _, _, _): return sessionID
        case .toolSuccess(let sessionID, _, _, _, _, _, _): return sessionID
        case .toolFailed(let sessionID, _, _, _, _, _, _, _): return sessionID
        }
    }

    var assistantMessageID: String {
        switch self {
        case .stepStarted(_, let messageID, _, _, _, _): return messageID
        case .stepStreamed(_, let messageID, _): return messageID
        case .stepEnded(_, let messageID, _, _): return messageID
        case .stepFailed(_, let messageID, _, _, _): return messageID
        case .textStarted(_, let messageID, _, _): return messageID
        case .textEnded(_, let messageID, _, _, _): return messageID
        case .textDelta(_, let messageID, _, _, _): return messageID
        case .reasoningStarted(_, let messageID, _, _): return messageID
        case .reasoningEnded(_, let messageID, _, _, _): return messageID
        case .reasoningDelta(_, let messageID, _, _, _): return messageID
        case .toolInputStarted(_, let messageID, _, _, _): return messageID
        case .toolInputDelta(_, let messageID, _, _, _): return messageID
        case .toolInputEnded(_, let messageID, _, _, _): return messageID
        case .toolCalled(_, let messageID, _, _, _): return messageID
        case .toolProgress(_, let messageID, _, _, _): return messageID
        case .toolSuccess(_, let messageID, _, _, _, _, _): return messageID
        case .toolFailed(_, let messageID, _, _, _, _, _, _): return messageID
        }
    }

    var created: Double {
        switch self {
        case .stepStarted(_, _, _, _, _, let created): return created
        case .stepStreamed(_, _, let created): return created
        case .stepEnded(_, _, _, let created): return created
        case .stepFailed(_, _, _, _, let created): return created
        case .textStarted(_, _, _, let created): return created
        case .textEnded(_, _, _, _, let created): return created
        case .textDelta(_, _, _, _, let created): return created
        case .reasoningStarted(_, _, _, let created): return created
        case .reasoningEnded(_, _, _, _, let created): return created
        case .reasoningDelta(_, _, _, _, let created): return created
        case .toolInputStarted(_, _, _, _, let created): return created
        case .toolInputDelta(_, _, _, _, let created): return created
        case .toolInputEnded(_, _, _, _, let created): return created
        case .toolCalled(_, _, _, _, let created): return created
        case .toolProgress(_, _, _, _, let created): return created
        case .toolSuccess(_, _, _, _, _, _, let created): return created
        case .toolFailed(_, _, _, _, _, _, _, let created): return created
        }
    }
}

/// Decoder output: `notApplicable` for types outside the verified families,
/// `event` for a fully decoded typed event, `malformed` for a recognized type
/// whose required fields are missing or ill-typed. `malformed` carries
/// best-effort attribution (nil when the id is missing or empty) so callers
/// can reconcile without guessing.
enum SessionTranscriptDecodeResult: Equatable, Sendable {
    case notApplicable
    case event(SessionTranscriptEvent)
    case malformed(sessionID: SessionID?, assistantMessageID: String?)
}

enum SessionTranscriptEventDecoder {
    /// Event families covered by the typed decoder/reducer. Shared with
    /// `SessionEventRouter.structuralRoute` so the two cannot drift.
    static let coveredTypes: Set<String> = [
        "session.step.started",
        "session.step.streamed",
        "session.step.ended",
        "session.step.failed",
        "session.text.started",
        "session.text.ended",
        "session.text.delta",
        "session.reasoning.started",
        "session.reasoning.ended",
        "session.reasoning.delta",
        "session.tool.input.started",
        "session.tool.input.delta",
        "session.tool.input.ended",
        "session.tool.called",
        "session.tool.progress",
        "session.tool.success",
        "session.tool.failed",
    ]

    static func decode(_ envelope: EventEnvelope) -> SessionTranscriptDecodeResult {
        guard coveredTypes.contains(envelope.type) else { return .notApplicable }
        guard let created = envelope.created, created.isFinite else {
            return .malformed(sessionID: bestEffortSessionID(envelope.data), assistantMessageID: bestEffortMessageID(envelope.data))
        }
        guard let data = envelope.data.objectValue else {
            return .malformed(sessionID: nil, assistantMessageID: nil)
        }
        guard let sessionID = nonEmptyString(data, key: "sessionID"),
              let messageID = nonEmptyString(data, key: "assistantMessageID") else {
            return .malformed(
                sessionID: bestEffortSessionID(envelope.data),
                assistantMessageID: bestEffortMessageID(envelope.data)
            )
        }
        let session = SessionID(rawValue: sessionID)
        let event: SessionTranscriptEvent? = switch envelope.type {
        case "session.step.started": decodeStepStarted(data, session: session, messageID: messageID, created: created)
        case "session.step.streamed": .stepStreamed(sessionID: session, messageID: messageID, created: created)
        case "session.step.ended": decodeStepEnded(data, session: session, messageID: messageID, created: created)
        case "session.step.failed": decodeStepFailed(data, session: session, messageID: messageID, created: created)
        case "session.text.started": decodeOrdinalSlot(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.textStarted)
        case "session.text.ended": decodeTerminalText(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.textEnded)
        case "session.text.delta": decodeDelta(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.textDelta)
        case "session.reasoning.started": decodeOrdinalSlot(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.reasoningStarted)
        case "session.reasoning.ended": decodeTerminalText(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.reasoningEnded)
        case "session.reasoning.delta": decodeDelta(data, session: session, messageID: messageID, created: created, make: SessionTranscriptEvent.reasoningDelta)
        case "session.tool.input.started": decodeToolInputStarted(data, session: session, messageID: messageID, created: created)
        case "session.tool.input.delta": decodeToolInputDelta(data, session: session, messageID: messageID, created: created)
        case "session.tool.input.ended": decodeToolInputEnded(data, session: session, messageID: messageID, created: created)
        case "session.tool.called": decodeToolCalled(data, session: session, messageID: messageID, created: created)
        case "session.tool.progress": decodeToolProgress(data, session: session, messageID: messageID, created: created)
        case "session.tool.success": decodeToolSuccess(data, session: session, messageID: messageID, created: created)
        case "session.tool.failed": decodeToolFailed(data, session: session, messageID: messageID, created: created)
        default: nil
        }
        guard let event else {
            return .malformed(sessionID: session, assistantMessageID: messageID)
        }
        return .event(event)
    }

    // MARK: - Family decoders (nil = malformed)

    private static func decodeStepStarted(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let agent = nonEmptyString(data, key: "agent"),
              let started = data["started"]?.numberValue,
              started.isFinite, started >= 0,
              let rawModel = data["model"],
              let model = try? TranscriptModelRef.decode(convert(rawModel)) else { return nil }
        return .stepStarted(sessionID: session, messageID: messageID, agent: agent, model: model, started: started, created: created)
    }

    private static func decodeStepEnded(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        // `cost` and `tokens` are required for well-formedness (the pinned
        // schema always carries them) but their values are not interpreted.
        guard let finish = data["finish"]?.stringValue,
              TranscriptAssistantMessage.validFinishes.contains(finish),
              data["cost"] != nil, data["cost"] != .null,
              data["tokens"] != nil, data["tokens"] != .null else { return nil }
        return .stepEnded(sessionID: session, messageID: messageID, finish: finish, created: created)
    }

    private static func decodeStepFailed(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let rawError = data["error"]?.objectValue,
              let error = try? TranscriptToolError.decode(convertObject(rawError)) else { return nil }
        let finish: String
        if let rawFinish = data["finish"] {
            guard let value = rawFinish.stringValue, value == "content-filter" else { return nil }
            finish = value
        } else {
            finish = "error"
        }
        return .stepFailed(sessionID: session, messageID: messageID, finish: finish, error: error, created: created)
    }

    private static func decodeOrdinalSlot(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double,
        make: (SessionID, String, Int, Double) -> SessionTranscriptEvent
    ) -> SessionTranscriptEvent? {
        guard let ordinal = ordinal(data) else { return nil }
        return make(session, messageID, ordinal, created)
    }

    private static func decodeTerminalText(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double,
        make: (SessionID, String, Int, String, Double) -> SessionTranscriptEvent
    ) -> SessionTranscriptEvent? {
        guard let ordinal = ordinal(data),
              let text = data["text"]?.stringValue else { return nil }
        return make(session, messageID, ordinal, text, created)
    }

    private static func decodeDelta(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double,
        make: (SessionID, String, Int, String, Double) -> SessionTranscriptEvent
    ) -> SessionTranscriptEvent? {
        guard let ordinal = ordinal(data),
              let delta = data["delta"]?.stringValue else { return nil }
        return make(session, messageID, ordinal, delta, created)
    }

    private static func decodeToolInputStarted(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let name = data["name"]?.stringValue else { return nil }
        return .toolInputStarted(sessionID: session, messageID: messageID, toolID: toolID, name: name, created: created)
    }

    private static func decodeToolInputDelta(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let delta = data["delta"]?.stringValue else { return nil }
        return .toolInputDelta(sessionID: session, messageID: messageID, toolID: toolID, delta: delta, created: created)
    }

    private static func decodeToolInputEnded(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let text = data["text"]?.stringValue else { return nil }
        return .toolInputEnded(sessionID: session, messageID: messageID, toolID: toolID, text: text, created: created)
    }

    private static func decodeToolCalled(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        // `executed` is required for well-formedness but carries no durable
        // fact the client model keeps, so its value is validated and dropped.
        guard let toolID = nonEmptyString(data, key: "id"),
              let rawInput = data["input"], rawInput.objectValue != nil,
              data["executed"]?.boolValue != nil else { return nil }
        return .toolCalled(sessionID: session, messageID: messageID, toolID: toolID, input: convert(rawInput), created: created)
    }

    private static func decodeToolProgress(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let rawMetadata = data["metadata"], rawMetadata.objectValue != nil else { return nil }
        return .toolProgress(sessionID: session, messageID: messageID, toolID: toolID, metadata: convert(rawMetadata), created: created)
    }

    private static func decodeToolSuccess(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let executed = data["executed"]?.boolValue,
              let content = decodeContent(data["content"]) else { return nil }
        let metadata: TranscriptJSONValue?
        if let rawMetadata = data["metadata"], rawMetadata != .null {
            guard rawMetadata.objectValue != nil else { return nil }
            metadata = convert(rawMetadata)
        } else {
            metadata = nil
        }
        return .toolSuccess(sessionID: session, messageID: messageID, toolID: toolID, content: content, executed: executed, metadata: metadata, created: created)
    }

    private static func decodeToolFailed(
        _ data: [String: EventJSONValue],
        session: SessionID,
        messageID: String,
        created: Double
    ) -> SessionTranscriptEvent? {
        guard let toolID = nonEmptyString(data, key: "id"),
              let rawError = data["error"]?.objectValue,
              let error = try? TranscriptToolError.decode(convertObject(rawError)),
              let executed = data["executed"]?.boolValue else { return nil }
        let content: [TranscriptToolOutput]?
        if let rawContent = data["content"], rawContent != .null {
            guard let decoded = decodeContent(rawContent) else { return nil }
            content = decoded
        } else {
            content = nil
        }
        let metadata: TranscriptJSONValue?
        if let rawMetadata = data["metadata"], rawMetadata != .null {
            guard rawMetadata.objectValue != nil else { return nil }
            metadata = convert(rawMetadata)
        } else {
            metadata = nil
        }
        return .toolFailed(sessionID: session, messageID: messageID, toolID: toolID, error: error, executed: executed, content: content, metadata: metadata, created: created)
    }

    /// Tool output must be a non-empty array of text/file records, reusing
    /// `TranscriptToolOutput.decode` semantics. Unknown or malformed items
    /// fail the event (unlike snapshot decoding, there are no neighbors to
    /// preserve here; the caller reconciles instead).
    private static func decodeContent(_ raw: EventJSONValue?) -> [TranscriptToolOutput]? {
        guard let raw, case .array(let items) = raw, !items.isEmpty else { return nil }
        var content: [TranscriptToolOutput] = []
        content.reserveCapacity(items.count)
        for item in items {
            guard let decoded = try? TranscriptToolOutput.decode(convert(item)) else { return nil }
            content.append(decoded)
        }
        return content
    }

    // MARK: - Field helpers

    private static func nonEmptyString(_ data: [String: EventJSONValue], key: String) -> String? {
        guard let value = data[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Ordinals are non-negative integers. A fractional, negative, or
    /// non-numeric ordinal is malformed.
    private static func ordinal(_ data: [String: EventJSONValue]) -> Int? {
        guard let value = data["ordinal"]?.numberValue,
              value.isFinite, value >= 0,
              value.truncatingRemainder(dividingBy: 1) == 0,
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func bestEffortSessionID(_ data: EventJSONValue) -> SessionID? {
        guard let raw = data.objectValue?["sessionID"]?.stringValue, !raw.isEmpty else { return nil }
        return SessionID(rawValue: raw)
    }

    private static func bestEffortMessageID(_ data: EventJSONValue) -> String? {
        guard let raw = data.objectValue?["assistantMessageID"]?.stringValue, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - Event/Transcript JSON bridge

    /// Mechanical conversion without interpretation: the Transcript JSON
    /// representation reuses the same null/bool/number/string/array/object
    /// shapes, so existing Transcript decoders apply unchanged.
    private static func convert(_ value: EventJSONValue) -> TranscriptJSONValue {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let items): return .array(items.map(convert))
        case .object(let object): return .object(object.mapValues(convert))
        }
    }

    private static func convertObject(_ object: [String: EventJSONValue]) -> [String: TranscriptJSONValue] {
        object.mapValues(convert)
    }
}

private extension EventJSONValue {
    var objectValue: [String: EventJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
