import Foundation

/// Presentation-safe summaries derived from the pinned discovery DTOs.
/// Values are not hardcoded: the backend remains authoritative for which agents
/// and models exist.

struct AgentSummary: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let mode: String
    let hidden: Bool

    init(info: AgentInfo) {
        id = info.id
        name = info.name
        description = info.description
        mode = info.mode
        hidden = info.hidden
    }

    /// Primary-selectable agents: `mode` is `primary`/`all` and the agent is not hidden.
    var isPrimary: Bool { (mode == "primary" || mode == "all") && !hidden }
}

struct ModelSummary: Equatable, Sendable, Identifiable {
    let ref: ModelRef
    let name: String
    let providerID: String
    let status: String?
    let enabled: Bool

    init(info: ModelInfo) {
        ref = ModelRef(id: info.id, providerID: info.providerID)
        name = info.name?.isEmpty == false ? info.name! : info.id
        providerID = info.providerID
        status = info.status
        enabled = info.enabled
    }

    var id: String { "\(ref.providerID)/\(ref.id)" }
}

enum SelectionProblem: Equatable, Sendable {
    case notConnected
    case noLocation
    case noSession
    case unauthorized
    case notFound
    case serviceUnavailable
    case backend(Int)
    case malformedResponse
    case requestFailed
    case unavailable

    init(_ error: SelectionAPIError) {
        switch error {
        case .notConnected: self = .notConnected
        case .unauthorized: self = .unauthorized
        case .notFound: self = .notFound
        case .serviceUnavailable: self = .serviceUnavailable
        case .backend(let code): self = .backend(code)
        case .malformedResponse: self = .malformedResponse
        case .requestFailed: self = .requestFailed
        }
    }

    var label: String {
        switch self {
        case .notConnected: return "not connected"
        case .noLocation: return "no location"
        case .noSession: return "no active session"
        case .unauthorized: return "not authorized"
        case .notFound: return "session not found"
        case .serviceUnavailable: return "service unavailable"
        case .backend(let code): return "server error \(code)"
        case .malformedResponse: return "malformed response"
        case .requestFailed: return "request failed"
        case .unavailable: return "not available"
        }
    }
}

enum SelectionDiscoveryState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(SelectionProblem)
}

enum AgentSelectionState: Equatable, Sendable {
    case idle
    case inProgress(agent: String)
    case rejected(agent: String, problem: SelectionProblem)
    case unknown(agent: String, problem: SelectionProblem)
}

enum ModelSelectionState: Equatable, Sendable {
    case idle
    case inProgress(model: ModelRef)
    case rejected(model: ModelRef, problem: SelectionProblem)
    case unknown(model: ModelRef, problem: SelectionProblem)
}

/// Authoritative session selection read back after a mutation (or on request).
struct SelectionConfirmation: Equatable, Sendable {
    let agent: String?
    let model: ModelRef?
}

/// Store-facing outcome mapped from the adapter's `SelectionMutationResult`.
enum SelectionMutationOutcome: Equatable, Sendable {
    case applied(confirmed: SelectionConfirmation?)
    case rejected(SelectionProblem)
    case unknown(SelectionProblem)
}
