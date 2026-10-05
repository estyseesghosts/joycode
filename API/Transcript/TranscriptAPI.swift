import Foundation

/// Contract adapter for the pinned session message history read.
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:
/// - `GET /api/session/{id}/message` -> `200 {data: Session.Message.Info[], cursor}`;
///   declared errors `400`/`401`/`404`/`500` (see
///   `docs/plan/r06-r07-contract-notes-2026-10-05.md`).
/// - History defaults to 50 newest-first (`desc`); limits are 1...200.
///   Ordering is internal sequence, not timestamp; pages preserve requested
///   order. Sending `cursor` together with `order` is rejected. Cursors are
///   opaque; both next/previous are emitted on every nonempty page, and an
///   empty page terminates paging.
/// - History context is the session-specific request. Authentication rides on
///   the passed `ServiceConnection` only; no legacy `parts` parameters exist.
///
/// This file owns request construction, client-side query validation, status
/// mapping, and envelope decoding. It owns no composition, store, paging UI,
/// live updates, or event handling.

enum TranscriptOrder: String, Sendable {
    case asc
    case desc
}

struct TranscriptQuery: Equatable, Sendable {
    var limit: Int?
    var order: TranscriptOrder?
    var cursor: String?

    static var defaultPage: TranscriptQuery {
        TranscriptQuery(limit: 50, order: .desc, cursor: nil)
    }
}

enum TranscriptQueryError: Error, Equatable, Sendable {
    case orderWithCursor
    case limitOutOfRange(Int)
}

enum TranscriptAPIError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case notFound
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
    case invalidQuery(TranscriptQueryError)
}

struct TranscriptAPI: Sendable {
    let transport: any HTTPTransport

    // MARK: - Request construction

    static func historyRequest(sessionID: SessionID, query: TranscriptQuery = .defaultPage) -> HTTPRequest {
        var items: [HTTPQueryItem] = []
        if let limit = query.limit { items.append(.init(name: "limit", value: String(limit))) }
        if let order = query.order { items.append(.init(name: "order", value: order.rawValue)) }
        if let cursor = query.cursor { items.append(.init(name: "cursor", value: cursor)) }
        return HTTPRequest(method: .get, relativePath: "/api/session/\(sessionID.rawValue)/message", queryItems: items)
    }

    /// Client-side validation matching the pinned contract: limits are
    /// 1...200, and `order` cannot coexist with an opaque `cursor`.
    static func validate(_ query: TranscriptQuery) throws {
        if let limit = query.limit, !(1...200).contains(limit) {
            throw TranscriptQueryError.limitOutOfRange(limit)
        }
        if query.order != nil, query.cursor != nil {
            throw TranscriptQueryError.orderWithCursor
        }
    }

    // MARK: - Operations

    /// Reads one history page in server order. Client-invalid queries fail
    /// before any request is sent. Envelope failures throw `malformedResponse`
    /// without fabricating messages; per-entry unknown/malformed variants
    /// decode to opaque fallbacks inside the page.
    func page(connection: ServiceConnection, sessionID: SessionID, query: TranscriptQuery = .defaultPage) async throws -> TranscriptPage {
        do {
            try Self.validate(query)
        } catch let error as TranscriptQueryError {
            throw TranscriptAPIError.invalidQuery(error)
        }
        return try await send(Self.historyRequest(sessionID: sessionID, query: query), connection: connection)
    }

    // MARK: - Internals

    private func send(_ request: HTTPRequest, connection: ServiceConnection) async throws -> TranscriptPage {
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard response.statusCode == 200 else {
                throw Self.map(statusCode: response.statusCode)
            }
            do {
                return try TranscriptPage.decode(response.body)
            } catch {
                throw TranscriptAPIError.malformedResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TranscriptAPIError {
            throw error
        } catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw TranscriptAPIError.unauthorized
            case .backend(let code): throw Self.map(statusCode: code)
            default: throw TranscriptAPIError.requestFailed
            }
        } catch {
            throw TranscriptAPIError.requestFailed
        }
    }

    private static func map(statusCode: Int) -> TranscriptAPIError {
        switch statusCode {
        case 400: return .backend(statusCode: 400)
        case 401: return .unauthorized
        case 404: return .notFound
        default: return .backend(statusCode: statusCode)
        }
    }
}
