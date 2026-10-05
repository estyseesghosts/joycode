import Foundation

struct SessionSummary: Equatable, Sendable {
    let id: SessionID; let parentID: SessionID?; let projectID: ProjectID; let title: String; let directory: URL
    var isRoot: Bool { parentID == nil }
    init(info: SessionInfo) { id = SessionID(rawValue: info.id); parentID = info.parentID.map(SessionID.init(rawValue:)); projectID = ProjectID(rawValue: info.projectID); title = info.title?.isEmpty == false ? info.title! : "Untitled Session"; directory = URL(fileURLWithPath: info.location.directory) }
}
struct SessionPage: Equatable, Sendable { let sessions: [SessionSummary]; let nextCursor: String?; let previousCursor: String? }
enum SessionProblem: Equatable, Sendable { case notConnected, noLocation, unauthorized, notFound, backend(Int), malformedResponse, requestFailed, preferencesUnreadable }

extension SessionProblem {
    init(_ error: SessionAPIError) {
        switch error {
        case .notConnected: self = .notConnected
        case .unauthorized: self = .unauthorized
        case .notFound: self = .notFound
        case .backend(let code): self = .backend(code)
        case .malformedResponse: self = .malformedResponse
        case .requestFailed: self = .requestFailed
        }
    }

    var label: String {
        switch self {
        case .notConnected: return "not connected"
        case .noLocation: return "no location"
        case .unauthorized: return "not authorized"
        case .notFound: return "session not found"
        case .backend(let code): return "server error \(code)"
        case .malformedResponse: return "malformed response"
        case .requestFailed: return "request failed"
        case .preferencesUnreadable: return "preferences unreadable"
        }
    }
}

struct SessionRenameRequest: Equatable, Sendable {
    let sessionID: SessionID
    let title: String
}
enum SessionRenameState: Equatable, Sendable {
    case idle
    case inProgress(SessionRenameRequest)
    case checking(SessionRenameRequest)
    case rejected(SessionRenameRequest, SessionProblem, serverTitle: String?)
    case unknown(SessionRenameRequest, serverTitle: String?)
}
enum SessionRenameOutcome: Equatable, Sendable {
    case applied(authoritative: SessionSummary?)
    case rejected(SessionProblem, authoritative: SessionSummary?)
    case unknown(SessionProblem, authoritative: SessionSummary?)
}

enum ActiveSessionState: Equatable, Sendable { case empty, loading, loaded(SessionSummary), failed(SessionProblem), creating, creationRejected(SessionProblem), creationUnknown(SessionID) }