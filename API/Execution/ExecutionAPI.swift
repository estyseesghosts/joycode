import Foundation

/// Adapter for the pinned execution operations (R09 API slice).
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:
/// - `GET /api/session/active` -> `200 {data: {[sessionID]: {type: "running"}}}`:
///   process-owned active execution, including asynchronous cleanup. There is
///   no `GET /api/session/{id}/status`.
/// - `POST /api/session/{id}/interrupt?resume=false` with no body ->
///   `200 {interrupted: boolean}`: async acceptance of the interruption, not
///   proof that work has stopped. An idle session may report `false`.
///   Declared errors for interrupt are `400`/`401`/`404` (see
///   `docs/v2_contract.md`); `409` is undeclared and handled conservatively
///   as `busy`. Silence or disconnect never proves stopped.
///
/// This file owns request construction, status mapping, and envelope decoding.
/// It owns no store classification, retry policy, orchestration, or UI, and
/// performs no service discovery, provider, or config calls. Each operation
/// sends exactly once on the passed `ServiceConnection`; authentication rides
/// on the connection only.

/// Transport boundary for execution reads and interrupts.
protocol ExecutionServing: Sendable {
    func activeSessions(connection: ServiceConnection) async throws -> Set<SessionID>
    func interrupt(connection: ServiceConnection, sessionID: SessionID) async throws -> Bool
}

enum ExecutionAPIError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case notFound
    case busy
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
}

/// Wire shape of one entry in the active-session map. Extra server fields are
/// ignored; only `type` is read.
private struct ExecutionActiveEntry: Decodable, Sendable {
    let type: String
}

private struct ExecutionActiveEnvelope: Decodable, Sendable {
    let data: [String: ExecutionActiveEntry]

    static func decode(_ data: Data) throws -> ExecutionActiveEnvelope {
        do { return try JSONDecoder().decode(ExecutionActiveEnvelope.self, from: data) }
        catch { throw ExecutionAPIError.malformedResponse }
    }
}

private struct ExecutionInterruptBody: Decodable, Sendable {
    let interrupted: Bool

    static func decode(_ data: Data) throws -> ExecutionInterruptBody {
        do { return try JSONDecoder().decode(ExecutionInterruptBody.self, from: data) }
        catch { throw ExecutionAPIError.malformedResponse }
    }
}

struct ExecutionAPI: ExecutionServing, Sendable {
    let transport: any HTTPTransport

    // MARK: - Request construction

    static func activeRequest() -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/session/active")
    }

    static func interruptRequest(sessionID: SessionID) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            relativePath: "/api/session/\(sessionID.rawValue)/interrupt",
            queryItems: [.init(name: "resume", value: "false")]
        )
    }

    // MARK: - Operations

    /// Reads the process-owned active set. Unknown or malformed entries fail
    /// closed: filtering them out could falsely confirm that execution stopped.
    func activeSessions(connection: ServiceConnection) async throws -> Set<SessionID> {
        let response = try await send(Self.activeRequest(), connection: connection)
        let envelope = try ExecutionActiveEnvelope.decode(response.body)
        var result = Set<SessionID>()
        for (key, entry) in envelope.data {
            guard key.hasPrefix("ses"), entry.type == "running" else {
                throw ExecutionAPIError.malformedResponse
            }
            result.insert(SessionID(rawValue: key))
        }
        return result
    }

    /// Requests interruption exactly once with `resume=false` and no body.
    /// The returned flag is async acceptance, not proof of stop. `false`
    /// (for example an idle session) is a valid answer, not an error.
    /// `409` is undeclared by the pinned contract and surfaces conservatively
    /// as `busy`; unknown transport failures and malformed success bodies are
    /// ambiguous (`requestFailed`/`malformedResponse`) and must never retry.
    func interrupt(connection: ServiceConnection, sessionID: SessionID) async throws -> Bool {
        let response = try await send(Self.interruptRequest(sessionID: sessionID), connection: connection)
        return try ExecutionInterruptBody.decode(response.body).interrupted
    }

    /// Declared execution rejections: `400`, `401`, `404`. `busy` (the
    /// conservative mapping of unexpected `409`) is not a declared rejection;
    /// every other status, transport failure, or malformed body is
    /// conservatively unknown at the store layer.
    static func isDeclaredRejection(_ error: ExecutionAPIError) -> Bool {
        switch error {
        case .backend(statusCode: 400), .unauthorized, .notFound:
            return true
        default:
            return false
        }
    }

    // MARK: - Internals

    private func send(_ request: HTTPRequest, connection: ServiceConnection) async throws -> HTTPResponse {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard response.statusCode == 200 else {
                throw Self.map(statusCode: response.statusCode)
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExecutionAPIError {
            throw error
        } catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw ExecutionAPIError.unauthorized
            case .backend(let code): throw Self.map(statusCode: code)
            default: throw ExecutionAPIError.requestFailed
            }
        } catch {
            throw ExecutionAPIError.requestFailed
        }
    }

    private static func map(statusCode: Int) -> ExecutionAPIError {
        switch statusCode {
        case 400: return .backend(statusCode: 400)
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return .busy
        default: return .backend(statusCode: statusCode)
        }
    }
}
