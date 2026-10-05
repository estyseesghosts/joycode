import Foundation

/// Wire DTOs for primary-agent/model discovery and session-scoped selection.
///
/// Pinned OpenCode v2.0.20, commit 84c9be93a56304a108f1a22df0c5d62c26d5b6ca:
/// - `GET /api/agent` -> `200 {location, data: Agent.Info[]}`; optional `location[directory]`.
/// - `GET /api/model` -> `200 {location, data: Model.Info[]}`; optional `location[directory]`.
/// - `POST /api/session/{id}/agent` body `{agent: string}` -> `204`; pinned session context.
/// - `POST /api/session/{id}/model` body `{model: Model.Ref}` -> `204`; pinned session context.
/// - `Session.Info` carries optional `agent`/`model`, so a readback is available.
///
/// Decoding is intentionally unknown-safe: declared keys are read, extra keys are ignored,
/// and non-essential keys fall back rather than failing the whole response.

/// `Model.Ref` (`{id, providerID, variant?}`). `id` + `providerID` identify a model;
/// an absent `variant` means the default variant.
struct ModelRef: Codable, Equatable, Hashable, Sendable {
    let id: String
    let providerID: String
    var variant: String?

    init(id: String, providerID: String, variant: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.variant = variant
    }
}

/// `Agent.Info` fields relevant to a primary-agent selector. `mode` is
/// `"subagent" | "primary" | "all"`; `hidden` excludes agents from discovery UI.
struct AgentInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let mode: String
    let hidden: Bool

    enum CodingKeys: String, CodingKey { case id, name, description, mode, hidden }

    init(id: String, name: String, description: String? = nil, mode: String = "all", hidden: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.mode = mode
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "all"
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// `Model.Info` fields relevant to a model selector. Only `id`/`providerID` are
/// required to build a `Model.Ref`; the rest is display/eligibility metadata.
struct ModelInfo: Decodable, Equatable, Sendable {
    let id: String
    let providerID: String
    let name: String?
    let enabled: Bool
    let status: String?

    enum CodingKeys: String, CodingKey { case id, providerID, name, enabled, status }

    init(id: String, providerID: String, name: String? = nil, enabled: Bool = true, status: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.enabled = enabled
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(String.self, forKey: .providerID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }
}

struct AgentListEnvelope: Decodable, Equatable, Sendable {
    let data: [AgentInfo]

    static func decode(_ data: Data) throws -> AgentListEnvelope {
        do { return try JSONDecoder().decode(AgentListEnvelope.self, from: data) }
        catch { throw SelectionAPIError.malformedResponse }
    }
}

struct ModelListEnvelope: Decodable, Equatable, Sendable {
    let data: [ModelInfo]

    static func decode(_ data: Data) throws -> ModelListEnvelope {
        do { return try JSONDecoder().decode(ModelListEnvelope.self, from: data) }
        catch { throw SelectionAPIError.malformedResponse }
    }
}

/// The session-selection subset of `Session.Info` used for readback/reconciliation.
struct SessionSelection: Decodable, Equatable, Sendable {
    let agent: String?
    let model: ModelRef?
}

struct SessionSelectionEnvelope: Decodable, Equatable, Sendable {
    let data: SessionSelection

    static func decode(_ data: Data) throws -> SessionSelectionEnvelope {
        do { return try JSONDecoder().decode(SessionSelectionEnvelope.self, from: data) }
        catch { throw SelectionAPIError.malformedResponse }
    }
}

enum SelectionAPIError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case notFound
    case serviceUnavailable
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
}

/// Outcome of a documented session selection mutation. A `204` is the only
/// accepted result; declared 400/401/404 are rejections; every other status,
/// transport failure, or lost reply is conservatively `unknown`.
enum SelectionMutationResult: Equatable, Sendable {
    case applied(confirmed: SessionSelection?)
    case rejected(SelectionAPIError)
    case unknown(SelectionAPIError)
}
