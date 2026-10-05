import Foundation

/// Adapter for the pinned session permission operations (R10 API slice).
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:
/// - `GET /api/session/{sessionID}/permission` ->
///   `200 {data: Permission.Request[]}`: pending-only list owned by the session.
///   Declared errors `400`/`401`/`404` (see `docs/v2_contract.md`).
/// - `GET /api/session/{sessionID}/permission/{requestID}` ->
///   `200 {data: Permission.Request}`: one pending request owned by the session.
///   Declared errors `400`/`401`/`404` (`SessionNotFound` or
///   `PermissionNotFound`).
/// - `POST /api/session/{sessionID}/permission/{requestID}/reply` with JSON
///   `{decision: "once"|"always"|"reject", message?}` -> `204`: the reply is
///   accepted, not proof of settlement. Declared errors `400`/`401`/`404`;
///   there is no declared `409`. A missing, repeated, or wrong-session reply is
///   `404`, which never proves the intended reply succeeded.
///
/// `Permission.Request` requires `id` (`^per`), `sessionID` (`^ses`),
/// `action`, and `resources: string[]`; `save: string[]`, `metadata` (record),
/// `source: {type: "tool", messageID, id}`, and `message` are optional. The
/// wire decision enum is `once|always|reject`; P1 exposes no permanent
/// auto-approval, so UI/store policy admits only `once`/`reject` (a separate
/// policy disposition would be required to offer `always`).
///
/// This file owns request construction, status mapping, envelope decoding, and
/// attribution validation. It owns no store classification, retry policy,
/// orchestration, or UI, and performs no service discovery, provider, or
/// config calls. Each operation sends exactly once on the passed
/// `ServiceConnection`; authentication rides on the connection only.
///
/// Reads require exactly `200` with a `data`-wrapped body; the reply requires
/// exactly `204`. Attribution is fail-closed: every returned request must
/// carry a `per`-prefixed id and the requested session, the single read must
/// additionally match the requested id, and a present `source` must be the
/// pinned `tool` shape. Anything unattributable is `malformedResponse` and
/// must be reread, never answered blindly.

/// Transport boundary for session permission reads and replies.
protocol PermissionServing: Sendable {
    func pendingRequests(connection: ServiceConnection, sessionID: SessionID) async throws -> [PermissionRequest]
    func permissionRequest(connection: ServiceConnection, sessionID: SessionID, requestID: String) async throws -> PermissionRequest
    func reply(connection: ServiceConnection, sessionID: SessionID, requestID: String, decision: PermissionDecision, message: String?) async throws
}

enum PermissionAPIError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case notFound
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
}

/// Wire reply decision (`Permission.Reply`). All three cases are encodable for
/// contract fidelity; P1 UI/store policy admits only `once`/`reject`.
enum PermissionDecision: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject
}

/// Opaque JSON value for the optional `metadata` record (`Record<string,
/// unknown>`). Unknown content is preserved, never interpreted.
enum PermissionMetadataValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PermissionMetadataValue])
    case object([String: PermissionMetadataValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([PermissionMetadataValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: PermissionMetadataValue].self))
    }
}

/// Pinned `source` shape attributing a request to one tool call. Only the
/// `tool` variant exists at the pinned revision; any other `type` fails
/// closed so an unattributable request can never be answered blindly.
struct PermissionSource: Decodable, Equatable, Sendable {
    let type: String
    let messageID: String
    let id: String

    var isToolAttribution: Bool {
        type == "tool" && !messageID.isEmpty && !id.isEmpty
    }
}

/// One `Permission.Request`. Extra server fields are ignored; the required
/// attribution fields are validated against the requesting context before the
/// request is surfaced.
struct PermissionRequest: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let sessionID: String
    let action: String
    let resources: [String]
    let save: [String]?
    let metadata: [String: PermissionMetadataValue]?
    let source: PermissionSource?
    let message: String?

    var description: String { "PermissionRequest(<redacted>)" }
    var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, action, resources, save, metadata, source, message
    }
}

private struct PermissionListEnvelope: Decodable, Sendable {
    let data: [PermissionRequest]

    static func decode(_ data: Data) throws -> PermissionListEnvelope {
        do { return try JSONDecoder().decode(PermissionListEnvelope.self, from: data) }
        catch { throw PermissionAPIError.malformedResponse }
    }
}

private struct PermissionSingleEnvelope: Decodable, Sendable {
    let data: PermissionRequest

    static func decode(_ data: Data) throws -> PermissionSingleEnvelope {
        do { return try JSONDecoder().decode(PermissionSingleEnvelope.self, from: data) }
        catch { throw PermissionAPIError.malformedResponse }
    }
}

struct PermissionAPI: PermissionServing, Sendable {
    let transport: any HTTPTransport

    // MARK: - Request construction

    static func pendingRequestsRequest(sessionID: SessionID) -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)/permission")
    }

    static func permissionRequest(sessionID: SessionID, requestID: String) -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)/permission/\(requestID)")
    }

    static func replyRequest(sessionID: SessionID, requestID: String, decision: PermissionDecision, message: String?) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            relativePath: "/api/session/\(sessionID.rawValue)/permission/\(requestID)/reply",
            body: try? HTTPJSON.encode(PermissionReplyBody(decision: decision, message: message))
        )
    }

    // MARK: - Operations

    /// Lists the session-owned pending requests. Every entry must attribute to
    /// the requested session; one unattributable entry fails the whole read
    /// rather than silently dropping a pending approval.
    func pendingRequests(connection: ServiceConnection, sessionID: SessionID) async throws -> [PermissionRequest] {
        let response = try await dispatch(
            Self.pendingRequestsRequest(sessionID: sessionID),
            connection: connection,
            expectedStatus: 200
        )
        let envelope = try PermissionListEnvelope.decode(response.body)
        for request in envelope.data {
            guard Self.isAttributable(request, sessionID: sessionID, requestID: nil) else {
                throw PermissionAPIError.malformedResponse
            }
        }
        return envelope.data
    }

    /// Reads one pending request. The returned id and session must match the
    /// requested pair; anything else stays ambiguous (`malformedResponse`).
    func permissionRequest(connection: ServiceConnection, sessionID: SessionID, requestID: String) async throws -> PermissionRequest {
        let response = try await dispatch(
            Self.permissionRequest(sessionID: sessionID, requestID: requestID),
            connection: connection,
            expectedStatus: 200
        )
        let request = try PermissionSingleEnvelope.decode(response.body).data
        guard Self.isAttributable(request, sessionID: sessionID, requestID: requestID) else {
            throw PermissionAPIError.malformedResponse
        }
        return request
    }

    /// Dispatches one reply with JSON `{decision, message?}`. Success is
    /// exactly `204` (accepted, not settlement proof). Unknown transport
    /// failures and non-204 replies are ambiguous and must never retry: a
    /// `404` here never proves the intended reply succeeded.
    func reply(connection: ServiceConnection, sessionID: SessionID, requestID: String, decision: PermissionDecision, message: String?) async throws {
        let response = try await dispatch(
            Self.replyRequest(sessionID: sessionID, requestID: requestID, decision: decision, message: message),
            connection: connection,
            expectedStatus: 204
        )
        guard response.body.isEmpty else { throw PermissionAPIError.malformedResponse }
    }

    /// Declared permission rejections: `400`, `401`, `404`. Every other
    /// status, transport failure, or malformed body is conservatively unknown
    /// at the store layer.
    static func isDeclaredRejection(_ error: PermissionAPIError) -> Bool {
        switch error {
        case .backend(statusCode: 400), .unauthorized, .notFound:
            return true
        default:
            return false
        }
    }

    // MARK: - Internals

    /// Attribution check: a `per`-prefixed id owned by the requested session,
    /// with the pinned `tool` source shape when a source is present. The
    /// single read additionally requires the requested id.
    static func isAttributable(_ request: PermissionRequest, sessionID: SessionID, requestID: String?) -> Bool {
        guard request.id.hasPrefix("per"),
              request.sessionID == sessionID.rawValue,
              !request.action.isEmpty
        else { return false }
        if let requestID, request.id != requestID { return false }
        if let source = request.source, !source.isToolAttribution { return false }
        return true
    }

    private func dispatch(_ request: HTTPRequest, connection: ServiceConnection, expectedStatus: Int) async throws -> HTTPResponse {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard response.statusCode == expectedStatus else {
                throw Self.map(statusCode: response.statusCode)
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PermissionAPIError {
            throw error
        } catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw PermissionAPIError.unauthorized
            case .backend(let code): throw Self.map(statusCode: code)
            default: throw PermissionAPIError.requestFailed
            }
        } catch {
            throw PermissionAPIError.requestFailed
        }
    }

    private static func map(statusCode: Int) -> PermissionAPIError {
        switch statusCode {
        case 400: return .backend(statusCode: 400)
        case 401: return .unauthorized
        case 404: return .notFound
        default: return .backend(statusCode: statusCode)
        }
    }
}

private struct PermissionReplyBody: Encodable {
    let decision: PermissionDecision
    let message: String?

    enum CodingKeys: String, CodingKey { case decision, message }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(message, forKey: .message)
    }
}
