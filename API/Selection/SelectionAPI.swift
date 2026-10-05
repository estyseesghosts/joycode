import Foundation

/// Adapter for the pinned v2.0.20 agent/model discovery and session selection
/// operations. Views never build these requests; they call through the store,
/// which calls this boundary.
struct SelectionAPI: Sendable {
    let transport: any HTTPTransport

    // MARK: - Request construction

    static func agentsRequest(location: URL?) -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/agent", queryItems: locationItems(location))
    }

    static func modelsRequest(location: URL?) -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/model", queryItems: locationItems(location))
    }

    static func switchAgentRequest(sessionID: SessionID, agent: String) -> HTTPRequest {
        HTTPRequest(method: .post, relativePath: "/api/session/\(sessionID.rawValue)/agent", body: try? HTTPJSON.encode(AgentSwitchBody(agent: agent)))
    }

    static func switchModelRequest(sessionID: SessionID, model: ModelRef) -> HTTPRequest {
        HTTPRequest(method: .post, relativePath: "/api/session/\(sessionID.rawValue)/model", body: try? HTTPJSON.encode(ModelSwitchBody(model: model)))
    }

    static func readSelectionRequest(sessionID: SessionID) -> HTTPRequest {
        HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)")
    }

    private static func locationItems(_ location: URL?) -> [HTTPQueryItem] {
        guard let location else { return [] }
        return [HTTPQueryItem(name: "location[directory]", value: location.path)]
    }

    // MARK: - Operations

    func listAgents(connection: ServiceConnection, location: URL?) async throws -> [AgentInfo] {
        try await send(Self.agentsRequest(location: location), connection: connection, decode: AgentListEnvelope.decode).data
    }

    func listModels(connection: ServiceConnection, location: URL?) async throws -> [ModelInfo] {
        try await send(Self.modelsRequest(location: location), connection: connection, decode: ModelListEnvelope.decode).data
    }

    func selectAgent(connection: ServiceConnection, sessionID: SessionID, agent: String) async throws -> SelectionMutationResult {
        try await mutate(Self.switchAgentRequest(sessionID: sessionID, agent: agent), connection: connection, sessionID: sessionID)
    }

    func selectModel(connection: ServiceConnection, sessionID: SessionID, model: ModelRef) async throws -> SelectionMutationResult {
        try await mutate(Self.switchModelRequest(sessionID: sessionID, model: model), connection: connection, sessionID: sessionID)
    }

    func readSelection(connection: ServiceConnection, sessionID: SessionID) async throws -> SessionSelection {
        try await send(Self.readSelectionRequest(sessionID: sessionID), connection: connection, decode: SessionSelectionEnvelope.decode).data
    }

    /// Declared selection rejections: `400`, `401`, `404`. Everything else is
    /// conservatively `unknown`.
    static func isDeclaredRejection(_ error: SelectionAPIError) -> Bool {
        switch error {
        case .backend(400), .unauthorized, .notFound: return true
        default: return false
        }
    }

    // MARK: - Internals

    private func mutate(_ request: HTTPRequest, connection: ServiceConnection, sessionID: SessionID) async throws -> SelectionMutationResult {
        do {
            try await requireNoContent(request, connection: connection)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SelectionAPIError {
            return Self.isDeclaredRejection(error) ? .rejected(error) : .unknown(error)
        } catch {
            return .unknown(.requestFailed)
        }

        // 204 accepted; best-effort readback on the same connection.
        do {
            let selection = try await readSelection(connection: connection, sessionID: sessionID)
            return .applied(confirmed: selection)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .applied(confirmed: nil)
        }
    }

    private func requireNoContent(_ request: HTTPRequest, connection: ServiceConnection) async throws {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard response.statusCode == 204 else {
                guard !(200..<300).contains(response.statusCode) else { throw SelectionAPIError.requestFailed }
                throw Self.map(statusCode: response.statusCode)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SelectionAPIError { throw error }
        catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw SelectionAPIError.unauthorized
            case .backend(let code): throw Self.map(statusCode: code)
            default: throw SelectionAPIError.requestFailed
            }
        } catch { throw SelectionAPIError.requestFailed }
    }

    private func send<T>(_ request: HTTPRequest, connection: ServiceConnection, decode: (Data) throws -> T) async throws -> T {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard (200..<300).contains(response.statusCode) else { throw Self.map(statusCode: response.statusCode) }
            return try decode(response.body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SelectionAPIError { throw error }
        catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw SelectionAPIError.unauthorized
            case .backend(let code): throw Self.map(statusCode: code)
            default: throw SelectionAPIError.requestFailed
            }
        } catch { throw SelectionAPIError.requestFailed }
    }

    private static func map(statusCode: Int) -> SelectionAPIError {
        switch statusCode {
        case 400: return .backend(statusCode: 400)
        case 401: return .unauthorized
        case 404: return .notFound
        case 503: return .serviceUnavailable
        default: return .backend(statusCode: statusCode)
        }
    }
}

private struct AgentSwitchBody: Encodable { let agent: String }
private struct ModelSwitchBody: Encodable { let model: ModelRef }
