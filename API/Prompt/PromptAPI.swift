import Foundation

/// Adapter for the pinned prompt admission operation.
///
/// Pinned OpenCode v2.0.20, commit `84c9be93a56304a108f1a22df0c5d62c26d5b6ca`:
/// - `POST /api/session/{sessionID}/prompt` with required `text` and optional
///   `id` (`^msg_`). Joycode always supplies a stable `msg_` identity.
///   No primary agent/model fields (selected on the session via R05
///   operations) and no legacy parts envelope.
/// - Success is exactly `200 {data: Session.Inbox.User}`: durable admission,
///   not completed assistant output. Declared errors: 400/401/404/409.
///   No blind retry or inferred idempotency guarantee.
///
/// The returned user inbox item requires `id`, `sessionID`, `type:"user"`,
/// `time.created`, `payload.text`, and `delivery` (`steer|queue`). The
/// admitted identity/text is validated against the frozen request before
/// admission is claimed; anything else stays ambiguous and the caller must
/// retain the original draft/context.
struct PromptRequest: Equatable, Sendable {
    let sessionID: SessionID
    let messageID: String
    let text: String
}

/// The admitted `Session.Inbox.User` record. Extra server fields are ignored;
/// the required admission fields are validated against the frozen request.
struct PromptAdmittedMessage: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let sessionID: String
    let type: String
    let time: PromptInboxTime
    let payload: PromptInboxPayload
    let delivery: PromptDelivery

    var text: String { payload.text }

    var description: String { "PromptAdmittedMessage(<redacted>)" }
    var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case id, sessionID, type, time, payload, delivery
    }
}

struct PromptInboxTime: Decodable, Equatable, Sendable {
    let created: Double
}

struct PromptInboxPayload: Decodable, Equatable, Sendable {
    let text: String
}

enum PromptDelivery: String, Decodable, Equatable, Sendable {
    case steer
    case queue
}

struct PromptSuccessEnvelope: Decodable, Sendable {
    let data: PromptAdmittedMessage

    static func decode(_ data: Data) throws -> PromptSuccessEnvelope {
        do { return try JSONDecoder().decode(PromptSuccessEnvelope.self, from: data) }
        catch { throw PromptAPIError.malformedResponse }
    }
}

enum PromptAPIError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case notFound
    case conflict
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
}

/// Outcome of a prompt admission attempt. Only a validated `200` inbox item
/// is admission; declared 400/401/404/409 are rejections; every other
/// status, transport failure, malformed/wrong success, or lost reply is
/// conservatively `unknown`. Cancellation is rethrown, never represented.
enum PromptSendResult: Equatable, Sendable {
    case admitted(PromptAdmittedMessage)
    case rejected(PromptAPIError)
    case unknown(PromptAPIError)
}

struct PromptAPI: Sendable {
    let transport: any HTTPTransport

    // MARK: - Request construction

    static func promptRequest(_ request: PromptRequest) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            relativePath: "/api/session/\(request.sessionID.rawValue)/prompt",
            body: try? HTTPJSON.encode(PromptBody(id: request.messageID, text: request.text))
        )
    }

    // MARK: - Operation

    /// Sends the prompt exactly once on the given connection. The transport
    /// resolves authentication from the connection; no new default client is
    /// created. No optimistic message is fabricated. Throws only
    /// `CancellationError`; all other failures are represented in the result.
    func send(connection: ServiceConnection, request: PromptRequest) async throws -> PromptSendResult {
        let response: HTTPResponse
        do {
            response = try await transport.send(connection: connection, request: Self.promptRequest(request))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPTransportError {
            switch error {
            case .unauthorized:
                return .rejected(.unauthorized)
            case .backend(let code):
                let mapped = Self.map(statusCode: code)
                return Self.isDeclaredRejection(mapped) ? .rejected(mapped) : .unknown(mapped)
            default:
                return .unknown(.requestFailed)
            }
        } catch {
            return .unknown(.requestFailed)
        }

        guard response.statusCode == 200 else {
            let mapped = Self.map(statusCode: response.statusCode)
            return Self.isDeclaredRejection(mapped) ? .rejected(mapped) : .unknown(mapped)
        }

        let admitted: PromptAdmittedMessage
        do {
            admitted = try PromptSuccessEnvelope.decode(response.body).data
        } catch let error as PromptAPIError {
            return .unknown(error)
        } catch {
            return .unknown(.requestFailed)
        }

        guard admitted.id == request.messageID,
              admitted.sessionID == request.sessionID.rawValue,
              admitted.type == "user",
              admitted.payload.text == request.text
        else {
            return .unknown(.requestFailed)
        }
        return .admitted(admitted)
    }

    /// Declared prompt rejections: `400`, `401`, `404`, `409`. Everything
    /// else is conservatively `unknown`.
    static func isDeclaredRejection(_ error: PromptAPIError) -> Bool {
        switch error {
        case .backend(statusCode: 400), .unauthorized, .notFound, .conflict:
            return true
        default:
            return false
        }
    }

    // MARK: - Internals

    private static func map(statusCode: Int) -> PromptAPIError {
        switch statusCode {
        case 400: return .backend(statusCode: 400)
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return .conflict
        default: return .backend(statusCode: statusCode)
        }
    }
}

private struct PromptBody: Encodable {
    let id: String
    let text: String
}
