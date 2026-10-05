import Foundation

/// A configured service destination. Service lifecycle/ensure is intentionally not part
/// of this contract.
struct ServiceEndpoint: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let baseURL: URL

    init(baseURL: URL) { self.baseURL = baseURL }

    var description: String { "ServiceEndpoint(baseURL: <redacted>)" }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [("baseURL", "<redacted>")], displayStyle: .struct)
    }
}

/// Credentials are requested by capability and must never be described with their secret.
struct ServiceCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let username: String
    let password: String

    var description: String {
        "ServiceCredential(username: \(username), password: <redacted>)"
    }

    var debugDescription: String {
        "ServiceCredential(username: \(username), password: <redacted>)"
    }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                ("username", username),
                ("password", "<redacted>")
            ],
            displayStyle: .struct
        )
    }
}

protocol CredentialCapability: Sendable {
    var safeDescription: String { get }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential?
}

/// The complete routing and authentication capability for one configured service.
/// Credentials are resolved by capability when needed and are not stored here.
struct ServiceConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let connectionID: ConnectionID
    let endpoint: ServiceEndpoint
    let credentialCapability: any CredentialCapability

    init(
        connectionID: ConnectionID,
        endpoint: ServiceEndpoint,
        credentialCapability: any CredentialCapability
    ) {
        self.connectionID = connectionID
        self.endpoint = endpoint
        self.credentialCapability = credentialCapability
    }

    var description: String {
        "ServiceConnection(connectionID: \(connectionID.rawValue), endpoint: <redacted>, credentials: <redacted>)"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                ("connectionID", connectionID.rawValue),
                ("endpoint", "<redacted>"),
                ("credentials", "<redacted>")
            ],
            displayStyle: .struct
        )
    }
}

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

struct HTTPQueryItem: Hashable, Sendable {
    let name: String
    let value: String?

    init(name: String, value: String? = nil) {
        self.name = name
        self.value = value
    }
}

/// V2-agnostic request data. Context is represented only by explicit query items.
struct HTTPRequest: Sendable {
    let method: HTTPMethod
    let relativePath: String
    let queryItems: [HTTPQueryItem]
    let body: Data?

    init(method: HTTPMethod, relativePath: String, queryItems: [HTTPQueryItem] = [], body: Data? = nil) {
        self.method = method
        self.relativePath = relativePath
        self.queryItems = queryItems
        self.body = body
    }
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol HTTPTransport: Sendable {
    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse
}

/// Streaming is separate from request/response transport and has one opening boundary.
protocol EventSource: Sendable {
    associatedtype Event: Sendable

    func open(connection: ServiceConnection, request: HTTPRequest) async throws -> AsyncThrowingStream<Event, Error>
}

protocol JoycodeClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

struct SystemJoycodeClock: JoycodeClock {
    var now: Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
