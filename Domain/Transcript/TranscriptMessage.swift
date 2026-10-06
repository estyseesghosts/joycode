import Foundation

/// Domain DTOs for the pinned session message history contract.
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:
/// - `GET /api/session/{id}/message` -> `200 {data: Session.Message.Info[], cursor}`
///   (see `docs/plan/r06-r07-contract-notes-2026-10-05.md`).
/// - History defaults to 50 newest-first (`desc`); limits are 1...200; ordering
///   is internal sequence, not timestamp. Pages preserve requested order: the
///   client must not re-sort by created time.
/// - Sending `cursor` together with `order` is rejected. Cursors are opaque.
/// - `Session.Message.Info` is a tagged union, not a legacy message-plus-parts
///   envelope. Assistant records require id/time/type/agent/model/content,
///   where `model` is a `Model.Ref` object (`{id, providerID, variant?}`),
///   not a string. Text/reasoning content requires `type` and `text`
///   (no part ID); tool content requires `type:"tool"`, `id`, `name`,
///   `state`, `time.created`, where `state` is a nested object discriminated
///   by `status` (streaming/running/completed/error), not a flat string.
///   Optional assistant `finish` (a fixed enum), structured `error`, and
///   `time.completed` are preserved for display; optional text/reasoning
///   timestamps are tolerated and ignored.
/// - Tool output is text `{type,text}` or file `{type,uri,mime,name?}`.
///   Structured persisted errors require `{type,message}` with optional
///   integer `status` (100...599).
/// - User file attachments can embed base64 bytes; those bytes must never be
///   copied into display/debug strings.
///
/// Decoding policy: the page envelope is validated strictly (missing/non-object
/// `cursor`, non-array `data`, or non-JSON bodies throw). Individual entries
/// decode strictly against their known shape but never fail the page: unknown
/// type tags and malformed known variants fall back to an opaque entry that
/// preserves the raw variant, so valid neighbors are never dropped or erased.
/// Within an assistant record, unknown or malformed content items likewise
/// fall back to a per-item opaque entry preserving the raw item, so valid
/// sibling content is never dropped. Only a missing/invalid assistant-level
/// `agent`, `model`, or `content` fails the whole record to opaque.
///
/// Identity scoping: text/reasoning content has no server ID; identity is
/// positional within the message snapshot only. Tool content identity is the
/// tool ID scoped to its message. No cross-resource total order is invented.

enum TranscriptDecodeError: Error, Equatable, Sendable {
    case malformed
}

// MARK: - Safe raw representation

/// Typed, `Sendable` raw JSON. Unknown variants and extra fields are preserved
/// here without being interpreted. Never interpolated into display strings.
enum TranscriptJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TranscriptJSONValue])
    case object([String: TranscriptJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([TranscriptJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: TranscriptJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var objectValue: [String: TranscriptJSONValue]? {
        if case .object(let object) = self { return object }
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

    func field(_ key: String) -> TranscriptJSONValue? { objectValue?[key] }

    func stringField(_ key: String) -> String? { field(key)?.stringValue }
}

extension TranscriptJSONValue: CustomStringConvertible, CustomDebugStringConvertible {
    /// Raw payloads (which may embed base64 attachment bytes) are never rendered.
    var description: String { "TranscriptJSONValue(<redacted>)" }
    var debugDescription: String { description }
}

// MARK: - Page envelope

struct TranscriptCursor: Decodable, Equatable, Sendable {
    let previous: String?
    let next: String?
}

/// One history page in server order. Order is preserved exactly as returned;
/// an empty `messages` terminates paging.
struct TranscriptPage: Equatable, Sendable {
    let messages: [TranscriptMessage]
    let cursor: TranscriptCursor

    static func decode(_ data: Data) throws -> TranscriptPage {
        do {
            let wire = try JSONDecoder().decode(TranscriptPageWire.self, from: data)
            return TranscriptPage(messages: wire.data.map(TranscriptMessage.from(raw:)), cursor: wire.cursor)
        } catch {
            throw TranscriptDecodeError.malformed
        }
    }
}

private struct TranscriptPageWire: Decodable {
    let data: [TranscriptJSONValue]
    let cursor: TranscriptCursor
}

// MARK: - Single-message envelope

extension TranscriptMessage {
    /// Decodes the `200 {data: Session.Message.Info}` envelope of
    /// `GET /api/session/{id}/message/{messageID}`. The envelope is strict
    /// (`data` must be an object); the entry itself follows the page rules:
    /// known shapes are typed, unknown or malformed variants become opaque.
    static func decode(envelope data: Data) throws -> TranscriptMessage {
        do {
            let wire = try JSONDecoder().decode(TranscriptMessageWire.self, from: data)
            guard wire.data.objectValue != nil else { throw TranscriptDecodeError.malformed }
            return TranscriptMessage.from(raw: wire.data)
        } catch {
            throw TranscriptDecodeError.malformed
        }
    }
}

private struct TranscriptMessageWire: Decodable {
    let data: TranscriptJSONValue
}

// MARK: - Messages

/// A single history record in server order.
enum TranscriptMessage: Equatable, Sendable {
    case user(TranscriptTextMessage)
    case system(TranscriptTextMessage)
    case synthetic(TranscriptTextMessage)
    case skill(TranscriptTextMessage)
    case assistant(TranscriptAssistantMessage)
    case agentSwitched(TranscriptRetainedVariant)
    case modelSwitched(TranscriptRetainedVariant)
    case locationSwitched(TranscriptRetainedVariant)
    case shell(TranscriptRetainedVariant)
    case compaction(TranscriptRetainedVariant)
    case idle(TranscriptRetainedVariant)
    case opaque(TranscriptOpaqueMessage)

    /// The history record ID when one could be extracted, if any.
    var messageID: String? {
        switch self {
        case .user(let message), .system(let message), .synthetic(let message), .skill(let message):
            return message.id
        case .assistant(let message): return message.id
        case .agentSwitched(let variant), .modelSwitched(let variant),
            .locationSwitched(let variant), .shell(let variant),
            .compaction(let variant), .idle(let variant):
            return variant.id
        case .opaque(let message): return message.id
        }
    }

    /// The wire type tag for known variants, or the extracted tag for opaque ones.
    var kind: String {
        switch self {
        case .user: return "user"
        case .system: return "system"
        case .synthetic: return "synthetic"
        case .skill: return "skill"
        case .assistant: return "assistant"
        case .agentSwitched: return "agent-switched"
        case .modelSwitched: return "model-switched"
        case .locationSwitched: return "location-switched"
        case .shell: return "shell"
        case .compaction: return "compaction"
        case .idle: return "idle"
        case .opaque(let message): return message.kind ?? "unknown"
        }
    }

    static func from(raw: TranscriptJSONValue) -> TranscriptMessage {
        do {
            return try decodeKnown(raw)
        } catch {
            return .opaque(TranscriptOpaqueMessage(
                id: raw.stringField("id"),
                kind: raw.stringField("type"),
                raw: raw
            ))
        }
    }

    private static func decodeKnown(_ raw: TranscriptJSONValue) throws -> TranscriptMessage {
        guard let object = raw.objectValue else { throw TranscriptEntryError.malformed }
        let type = try TranscriptEntryError.requireString(object, key: "type")
        switch type {
        case "user": return try .user(TranscriptTextMessage.decode(object))
        case "system": return try .system(TranscriptTextMessage.decode(object))
        case "synthetic": return try .synthetic(TranscriptTextMessage.decode(object))
        case "skill": return try .skill(TranscriptTextMessage.decode(object))
        case "assistant": return try .assistant(TranscriptAssistantMessage.decode(object))
        case "agent-switched":
            return try .agentSwitched(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        case "model-switched":
            return try .modelSwitched(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        case "location-switched":
            return try .locationSwitched(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        case "shell":
            return try .shell(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        case "compaction":
            return try .compaction(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        case "idle":
            return try .idle(TranscriptRetainedVariant.decode(kind: type, object: object, raw: raw))
        default: throw TranscriptEntryError.unknownType
        }
    }
}

extension TranscriptMessage: CustomStringConvertible, CustomDebugStringConvertible {
    /// Kind and record ID only. Text, tool payloads, and raw variants
    /// (which may embed base64 attachment bytes) are never rendered.
    var description: String {
        if let id = messageID { return "TranscriptMessage.\(kind)(id: \(id))" }
        return "TranscriptMessage.\(kind)(id: <missing>)"
    }

    var debugDescription: String { description }
}

private enum TranscriptEntryError: Error {
    case malformed
    case unknownType

    static func requireString(_ object: [String: TranscriptJSONValue], key: String) throws -> String {
        guard let value = object[key]?.stringValue else { throw TranscriptEntryError.malformed }
        return value
    }

    /// `time.created` must be a finite number; non-finite or missing times
    /// must not become false facts.
    static func requireCreated(_ object: [String: TranscriptJSONValue]) throws -> Double {
        guard let time = object["time"]?.objectValue,
              let created = time["created"]?.numberValue,
              created.isFinite else { throw TranscriptEntryError.malformed }
        return created
    }
}

/// A text-carrying history record (`user`, `system`, `synthetic`, `skill`).
/// Extra fields (attachments, metadata) are tolerated and ignored.
struct TranscriptTextMessage: Equatable, Sendable {
    let id: String
    let created: Double
    let text: String

    static func decode(_ object: [String: TranscriptJSONValue]) throws -> TranscriptTextMessage {
        TranscriptTextMessage(
            id: try TranscriptEntryError.requireString(object, key: "id"),
            created: try TranscriptEntryError.requireCreated(object),
            text: try TranscriptEntryError.requireString(object, key: "text")
        )
    }
}

extension TranscriptTextMessage: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptTextMessage(id: \(id), text: <redacted>)" }
    var debugDescription: String { description }
}

/// Pinned `Model.Ref` (`{id, providerID, variant?}`). `id` + `providerID`
/// identify the model; an absent `variant` means the default variant.
/// Kept as a Transcript-domain type so history decoding does not couple to
/// the selection feature's wire DTO.
struct TranscriptModelRef: Equatable, Sendable {
    let id: String
    let providerID: String
    let variant: String?

    static func decode(_ raw: TranscriptJSONValue) throws -> TranscriptModelRef {
        guard let object = raw.objectValue else { throw TranscriptEntryError.malformed }
        let variant = object["variant"]
        if variant != nil, variant?.stringValue == nil { throw TranscriptEntryError.malformed }
        return TranscriptModelRef(
            id: try TranscriptEntryError.requireString(object, key: "id"),
            providerID: try TranscriptEntryError.requireString(object, key: "providerID"),
            variant: variant?.stringValue
        )
    }
}

/// An assistant history record with tagged content in server order.
///
/// `model` is the pinned `Model.Ref` object (`{id, providerID, variant?}`).
/// Optional `finish` (when present, one of `stop`, `length`, `tool-calls`,
/// `content-filter`, `error`, `unknown`), structured `error`, and
/// `time.completed` are preserved for display; a string-typed `model`
/// (or missing `agent`/`model`/`content`, or an off-enum/non-string `finish`)
/// fails the whole record to an opaque message rather than a false fact.
/// Unknown or malformed content items become per-item opaque entries so
/// valid siblings are preserved.
struct TranscriptAssistantMessage: Equatable, Sendable {
    let id: String
    let created: Double
    let completed: Double?
    let agent: String
    let model: TranscriptModelRef
    let finish: String?
    let error: TranscriptToolError?
    let content: [TranscriptContent]

    /// Pinned finish enum (`Session.Message.Assistant.finish`).
    static let validFinishes: Set<String> = [
        "stop", "length", "tool-calls", "content-filter", "error", "unknown"
    ]

    static func decode(_ object: [String: TranscriptJSONValue]) throws -> TranscriptAssistantMessage {
        guard let rawContent = object["content"],
              case .array(let items) = rawContent else { throw TranscriptEntryError.malformed }
        guard let rawModel = object["model"] else { throw TranscriptEntryError.malformed }
        let time = object["time"]?.objectValue
        let completed = time?["completed"]?.numberValue.flatMap { $0.isFinite ? $0 : nil }
        return TranscriptAssistantMessage(
            id: try TranscriptEntryError.requireString(object, key: "id"),
            created: try TranscriptEntryError.requireCreated(object),
            completed: completed,
            agent: try TranscriptEntryError.requireString(object, key: "agent"),
            model: try TranscriptModelRef.decode(rawModel),
            finish: try object["finish"].map { rawFinish in
                guard let value = rawFinish.stringValue,
                      Self.validFinishes.contains(value) else { throw TranscriptEntryError.malformed }
                return value
            },
            error: try object["error"].map { rawError in
                guard let errorObject = rawError.objectValue else { throw TranscriptEntryError.malformed }
                return try TranscriptToolError.decode(errorObject)
            },
            content: items.map(TranscriptContent.from(raw:))
        )
    }

    /// Stable content identity: text/reasoning are positional within this
    /// message snapshot only; tools use the tool ID scoped to this message.
    func contentID(at index: Int) -> TranscriptContentID? {
        guard content.indices.contains(index) else { return nil }
        if case .tool(let tool) = content[index] {
            return .tool(messageID: id, toolID: tool.id)
        }
        return .positional(messageID: id, index: index)
    }
}

extension TranscriptAssistantMessage: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptAssistantMessage(id: \(id), content: <redacted>)" }
    var debugDescription: String { description }
}

/// A structured variant retained without interpretation
/// (`agent-switched`, `model-switched`, `location-switched`, `shell`,
/// `compaction`, `idle`). The raw value preserves structured data for a
/// visible fallback; it is never rendered into display strings.
struct TranscriptRetainedVariant: Equatable, Sendable {
    let kind: String
    let id: String
    let created: Double
    let raw: TranscriptJSONValue

    static func decode(kind: String, object: [String: TranscriptJSONValue], raw: TranscriptJSONValue) throws -> TranscriptRetainedVariant {
        TranscriptRetainedVariant(
            kind: kind,
            id: try TranscriptEntryError.requireString(object, key: "id"),
            created: try TranscriptEntryError.requireCreated(object),
            raw: raw
        )
    }
}

extension TranscriptRetainedVariant: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptRetainedVariant.\(kind)(id: \(id))" }
    var debugDescription: String { description }
}

/// Per-entry fallback for unknown type tags and malformed known variants.
/// Neighbors decode independently, so this never drops surrounding records.
struct TranscriptOpaqueMessage: Equatable, Sendable {
    let id: String?
    let kind: String?
    let raw: TranscriptJSONValue
}

extension TranscriptOpaqueMessage: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptOpaqueMessage(kind: \(kind ?? "unknown"), id: \(id ?? "<missing>"))" }
    var debugDescription: String { description }
}

// MARK: - Assistant content

enum TranscriptContent: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case tool(TranscriptToolContent)
    case opaque(TranscriptOpaqueContent)

    /// Per-item fallback: unknown type tags and malformed known content
    /// become opaque entries preserving the raw item, so valid siblings
    /// in the same message are never dropped.
    static func from(raw: TranscriptJSONValue) -> TranscriptContent {
        do {
            return try decode(raw)
        } catch TranscriptEntryError.unknownType {
            return .opaque(TranscriptOpaqueContent(
                kind: raw.stringField("type"),
                reason: "unknown-content-type",
                raw: raw
            ))
        } catch {
            return .opaque(TranscriptOpaqueContent(
                kind: raw.stringField("type"),
                reason: "malformed-content",
                raw: raw
            ))
        }
    }

    static func decode(_ raw: TranscriptJSONValue) throws -> TranscriptContent {
        guard let object = raw.objectValue else { throw TranscriptEntryError.malformed }
        let type = try TranscriptEntryError.requireString(object, key: "type")
        switch type {
        case "text":
            return try .text(TranscriptEntryError.requireString(object, key: "text"))
        case "reasoning":
            return try .reasoning(TranscriptEntryError.requireString(object, key: "text"))
        case "tool":
            return try .tool(TranscriptToolContent.decode(object))
        default:
            throw TranscriptEntryError.unknownType
        }
    }
}

/// Per-item fallback for unknown or malformed assistant content. Siblings
/// decode independently, so this never drops surrounding content. The raw
/// item preserves structured data for a visible fallback; it is never
/// rendered into display strings. `reason` uses a fixed vocabulary so the
/// visible fallback cannot echo payload bytes.
struct TranscriptOpaqueContent: Equatable, Sendable {
    let kind: String?
    let reason: String
    let raw: TranscriptJSONValue
}

extension TranscriptOpaqueContent: CustomStringConvertible, CustomDebugStringConvertible {
    /// Kind and fixed reason only. The raw item (which may embed structured
    /// payload bytes) is never rendered.
    var description: String { "TranscriptOpaqueContent(kind: \(kind ?? "unknown"), reason: \(reason))" }
    var debugDescription: String { description }
}

extension TranscriptContent: CustomStringConvertible, CustomDebugStringConvertible {
    /// Content kinds and tool identity only. Text payloads and raw items
    /// (which may embed structured data) are never rendered.
    var description: String {
        switch self {
        case .text: return "TranscriptContent.text(<redacted>)"
        case .reasoning: return "TranscriptContent.reasoning(<redacted>)"
        case .tool(let tool): return String(describing: tool)
        case .opaque(let opaque):
            return "TranscriptContent.opaque(kind: \(opaque.kind ?? "unknown"), reason: \(opaque.reason))"
        }
    }

    var debugDescription: String { description }
}

/// Content identity scoping: positional keys belong to the full message
/// snapshot only; tool keys are tool IDs scoped to their message.
enum TranscriptContentID: Hashable, Sendable {
    case positional(messageID: String, index: Int)
    case tool(messageID: String, toolID: String)
}

struct TranscriptToolContent: Equatable, Sendable {
    let id: String
    let name: String
    let created: Double
    let state: TranscriptToolState

    /// `state` is a nested object discriminated by `status`; a flat string
    /// state (or a missing/non-object state) is malformed.
    static func decode(_ object: [String: TranscriptJSONValue]) throws -> TranscriptToolContent {
        guard let rawState = object["state"],
              let stateObject = rawState.objectValue else { throw TranscriptEntryError.malformed }
        return TranscriptToolContent(
            id: try TranscriptEntryError.requireString(object, key: "id"),
            name: try TranscriptEntryError.requireString(object, key: "name"),
            created: try TranscriptEntryError.requireCreated(object),
            state: try TranscriptToolState.decode(stateObject)
        )
    }
}

extension TranscriptToolContent: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptToolContent(id: \(id), name: \(name), state: \(state.kind))" }
    var debugDescription: String { description }
}

/// Tool lifecycle states decoded from the nested `state` object. Each state
/// enforces its pinned input/output shape: streaming input is a string;
/// running input/metadata are objects; completed has input plus nonempty tool
/// content with optional metadata; error has input plus a structured error
/// with optional (when present, nonempty) content and optional metadata.
enum TranscriptToolState: Equatable, Sendable {
    case streaming(input: String)
    case running(input: TranscriptJSONValue, metadata: TranscriptJSONValue)
    case completed(input: TranscriptJSONValue, content: [TranscriptToolOutput], metadata: TranscriptJSONValue?)
    case error(input: TranscriptJSONValue, error: TranscriptToolError, content: [TranscriptToolOutput]?, metadata: TranscriptJSONValue?)

    var kind: String {
        switch self {
        case .streaming: return "streaming"
        case .running: return "running"
        case .completed: return "completed"
        case .error: return "error"
        }
    }

    /// Decodes the nested `state` object, discriminated by `status`.
    static func decode(_ object: [String: TranscriptJSONValue]) throws -> TranscriptToolState {
        let status = try TranscriptEntryError.requireString(object, key: "status")
        guard let input = object["input"] else { throw TranscriptEntryError.malformed }
        switch status {
        case "streaming":
            guard let text = input.stringValue else { throw TranscriptEntryError.malformed }
            return .streaming(input: text)
        case "running":
            guard input.objectValue != nil,
                  let metadata = object["metadata"], metadata.objectValue != nil else {
                throw TranscriptEntryError.malformed
            }
            return .running(input: input, metadata: metadata)
        case "completed":
            guard input.objectValue != nil else { throw TranscriptEntryError.malformed }
            return .completed(
                input: input,
                content: try requireNonemptyContent(object),
                metadata: try optionalMetadata(object)
            )
        case "error":
            guard input.objectValue != nil,
                  let rawError = object["error"]?.objectValue else {
                throw TranscriptEntryError.malformed
            }
            let error = try TranscriptToolError.decode(rawError)
            let content: [TranscriptToolOutput]?
            if object["content"] != nil {
                content = try requireNonemptyContent(object)
            } else {
                content = nil
            }
            return .error(input: input, error: error, content: content, metadata: try optionalMetadata(object))
        default:
            throw TranscriptEntryError.unknownType
        }
    }

    /// Optional `metadata` is preserved when present; a present-but-non-object
    /// value is malformed.
    private static func optionalMetadata(
        _ object: [String: TranscriptJSONValue]
    ) throws -> TranscriptJSONValue? {
        guard let metadata = object["metadata"] else { return nil }
        guard metadata.objectValue != nil else { throw TranscriptEntryError.malformed }
        return metadata
    }

    private static func requireNonemptyContent(
        _ object: [String: TranscriptJSONValue]
    ) throws -> [TranscriptToolOutput] {
        guard let value = object["content"],
              case .array(let items) = value, !items.isEmpty else {
            throw TranscriptEntryError.malformed
        }
        return try items.map(TranscriptToolOutput.decode(_:))
    }
}

/// Tool output: text `{type,text}` or file `{type,uri,mime,name?}`.
enum TranscriptToolOutput: Equatable, Sendable {
    case text(String)
    case file(uri: String, mime: String, name: String?)

    static func decode(_ raw: TranscriptJSONValue) throws -> TranscriptToolOutput {        guard let object = raw.objectValue else { throw TranscriptEntryError.malformed }
        let type = try TranscriptEntryError.requireString(object, key: "type")
        switch type {
        case "text":
            return try .text(TranscriptEntryError.requireString(object, key: "text"))
        case "file":
            return try .file(
                uri: TranscriptEntryError.requireString(object, key: "uri"),
                mime: TranscriptEntryError.requireString(object, key: "mime"),
                name: object["name"]?.stringValue
            )
        default:
            throw TranscriptEntryError.unknownType
        }
    }
}

/// Structured persisted tool error `{type,message}` with optional integer
/// `status` (100...599). A present-but-non-integer or out-of-range status
/// is malformed.
struct TranscriptToolError: Equatable, Sendable {
    let type: String
    let message: String
    let status: Int?

    static func decode(_ object: [String: TranscriptJSONValue]) throws -> TranscriptToolError {
        TranscriptToolError(
            type: try TranscriptEntryError.requireString(object, key: "type"),
            message: try TranscriptEntryError.requireString(object, key: "message"),
            status: try optionalStatus(object)
        )
    }

    private static func optionalStatus(_ object: [String: TranscriptJSONValue]) throws -> Int? {
        guard let raw = object["status"] else { return nil }
        guard case .number(let value) = raw,
              value.isFinite,
              value.truncatingRemainder(dividingBy: 1) == 0,
              (100...599).contains(Int(value)) else { throw TranscriptEntryError.malformed }
        return Int(value)
    }
}

extension TranscriptToolError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "TranscriptToolError(type: \(type), message: <redacted>)" }
    var debugDescription: String { description }
}

extension TranscriptToolState: CustomStringConvertible, CustomDebugStringConvertible {
    /// Lifecycle kind only. Inputs, outputs, errors, and metadata (which may
    /// embed structured payload bytes) are never rendered. Typed accessors
    /// remain available for actual rendering.
    var description: String { "TranscriptToolState.\(kind)(<redacted>)" }
    var debugDescription: String { description }
}

extension TranscriptToolOutput: CustomStringConvertible, CustomDebugStringConvertible {
    /// Output kind only. Text bytes and file locations are never rendered
    /// into display strings; typed cases remain available for rendering.
    var description: String {
        switch self {
        case .text: return "TranscriptToolOutput.text(<redacted>)"
        case .file: return "TranscriptToolOutput.file(<redacted>)"
        }
    }

    var debugDescription: String { description }
}
