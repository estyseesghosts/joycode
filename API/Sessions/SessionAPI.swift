import Foundation

enum SessionAPIError: Error, Equatable, Sendable { case notConnected, unauthorized, notFound, backend(statusCode: Int), malformedResponse, requestFailed }
enum SessionOrder: String, Sendable { case asc, desc }
enum SessionParentFilter: Equatable, Sendable { case any, roots, parent(SessionID) }

struct SessionListQuery: Equatable, Sendable {
    var parent: SessionParentFilter = .any
    var directory: URL? = nil
    var limit: Int? = nil
    var order: SessionOrder? = nil
    var cursor: String? = nil
}

struct SessionCreateRequest: Equatable, Sendable { let id: SessionID; let title: String?; let location: URL }

enum SessionRenameResult: Equatable, Sendable {
    case applied(authoritative: SessionInfo?)
    case rejected(SessionAPIError, authoritative: SessionInfo?)
    case unknown(SessionAPIError, authoritative: SessionInfo?)
}

struct SessionAPI: Sendable {
    let transport: any HTTPTransport

    static func listRequest(query: SessionListQuery) -> HTTPRequest {
        var items: [HTTPQueryItem] = []
        switch query.parent { case .any: break; case .roots: items.append(.init(name: "parentID", value: "null")); case .parent(let id): items.append(.init(name: "parentID", value: id.rawValue)) }
        if let directory = query.directory { items.append(.init(name: "directory", value: directory.path)) }
        if let limit = query.limit, limit > 0 { items.append(.init(name: "limit", value: String(limit))) }
        if let order = query.order { items.append(.init(name: "order", value: order.rawValue)) }
        if let cursor = query.cursor { items.append(.init(name: "cursor", value: cursor)) }
        return HTTPRequest(method: .get, relativePath: "/api/session", queryItems: items)
    }
    static func getRequest(sessionID: SessionID) -> HTTPRequest { HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)") }
    static func historyRequest(sessionID: SessionID, limit: Int? = nil, cursor: String? = nil) -> HTTPRequest {
        var items: [HTTPQueryItem] = []
        if let limit, limit > 0 { items.append(.init(name: "limit", value: String(limit))) }
        if let cursor { items.append(.init(name: "cursor", value: cursor)) }
        return HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)/message", queryItems: items)
    }
    static func createRequest(_ request: SessionCreateRequest) -> HTTPRequest {
        var body: [String: AnyEncodable] = ["id": AnyEncodable(request.id.rawValue), "location": AnyEncodable(["directory": request.location.path])]
        if let title = request.title { body["title"] = AnyEncodable(title) }
        return HTTPRequest(method: .post, relativePath: "/api/session", body: try? HTTPJSON.encode(body))
    }
    static func updateTitleRequest(sessionID: SessionID, title: String) -> HTTPRequest {
        HTTPRequest(method: .patch, relativePath: "/api/session/\(sessionID.rawValue)", body: try? HTTPJSON.encode(["title": AnyEncodable(title)]))
    }

    func list(connection: ServiceConnection, query: SessionListQuery) async throws -> SessionListEnvelope { try await send(Self.listRequest(query: query), connection: connection, decode: SessionListEnvelope.decode) }
    func get(connection: ServiceConnection, sessionID: SessionID) async throws -> SessionInfo { try await send(Self.getRequest(sessionID: sessionID), connection: connection, decode: SessionEnvelope.decode).data }
    func create(connection: ServiceConnection, request: SessionCreateRequest) async throws -> SessionInfo { try await send(Self.createRequest(request), connection: connection, decode: SessionEnvelope.decode).data }
    func updateTitle(connection: ServiceConnection, sessionID: SessionID, title: String) async throws {
        do {
            let response = try await transport.send(connection: connection, request: Self.updateTitleRequest(sessionID: sessionID, title: title))
            guard response.statusCode == 204 else {
                guard !(200..<300).contains(response.statusCode) else { throw SessionAPIError.requestFailed }
                throw Self.map(statusCode: response.statusCode)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SessionAPIError { throw error }
        catch let error as HTTPTransportError {
            switch error { case .unauthorized: throw SessionAPIError.unauthorized; case .backend(let code): throw Self.map(statusCode: code); default: throw SessionAPIError.requestFailed }
        } catch { throw SessionAPIError.requestFailed }
    }

    static func isDeclaredRenameRejection(_ error: SessionAPIError) -> Bool {
        switch error {
        case .backend(400), .unauthorized, .notFound: return true
        default: return false
        }
    }

    func rename(connection: ServiceConnection, sessionID: SessionID, title: String) async throws -> SessionRenameResult {
        do {
            try await updateTitle(connection: connection, sessionID: sessionID, title: title)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionAPIError {
            let readback = try await readbackAfterPatchError(connection: connection, sessionID: sessionID)
            return classifyRenameError(error, readback: readback)
        } catch {
            let readback = try await readbackAfterPatchError(connection: connection, sessionID: sessionID)
            return classifyRenameError(.requestFailed, readback: readback)
        }

        // PATCH succeeded (204); perform readback on the same connection.
        do {
            let readback = try await get(connection: connection, sessionID: sessionID)
            return .applied(authoritative: readback)
        } catch is CancellationError { throw CancellationError() }
        catch { return .applied(authoritative: nil) }
    }

    /// Performs a GET readback after a PATCH error. Rethrows `CancellationError`.
    private func readbackAfterPatchError(connection: ServiceConnection, sessionID: SessionID) async throws -> SessionInfo? {
        do {
            return try await get(connection: connection, sessionID: sessionID)
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func classifyRenameError(_ error: SessionAPIError, readback: SessionInfo?) -> SessionRenameResult {
        if Self.isDeclaredRenameRejection(error) { return .rejected(error, authoritative: readback) }
        return .unknown(error, authoritative: readback)
    }

    private static func map(statusCode: Int) -> SessionAPIError {
        switch statusCode { case 400: return .backend(statusCode: 400); case 401: return .unauthorized; case 404: return .notFound; default: return .backend(statusCode: statusCode) }
    }

    private func send<T>(_ request: HTTPRequest, connection: ServiceConnection, decode: (Data) throws -> T) async throws -> T {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard (200..<300).contains(response.statusCode) else { throw SessionAPIError.backend(statusCode: response.statusCode) }
            return try decode(response.body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SessionAPIError { throw error }
        catch let error as HTTPTransportError {
            switch error { case .unauthorized: throw SessionAPIError.unauthorized; case .backend(let code): throw code == 404 ? SessionAPIError.notFound : SessionAPIError.backend(statusCode: code); default: throw SessionAPIError.requestFailed }
        } catch { throw SessionAPIError.requestFailed }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeValue = value.encode }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}