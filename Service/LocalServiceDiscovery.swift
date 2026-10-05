import Foundation

enum ServiceVersionRequirement: Sendable, Equatable {
    case any
    case exact(String)
}

struct LocalServiceConnection: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let connection: ServiceConnection
    let registration: ServiceRegistration
    let info: ServerInfo

    var description: String { "LocalServiceConnection(<redacted>)" }

    var debugDescription: String { "LocalServiceConnection(<redacted>)" }

    var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>(), displayStyle: .struct)
    }
}

struct LocalServiceDiscovery: Sendable {
    let registrationReader: LocalServiceRegistrationReader
    let transport: any HTTPTransport

    init(registrationReader: LocalServiceRegistrationReader, transport: any HTTPTransport) {
        self.registrationReader = registrationReader
        self.transport = transport
    }

    func discover(
        connectionID: ConnectionID = ConnectionID(rawValue: "local-service"),
        version: ServiceVersionRequirement = .any
    ) async throws -> LocalServiceConnection {
        try Task.checkCancellation()
        let registration = try registrationReader.read()
        guard let url = URL(string: registration.url), isSafeLoopback(url) else {
            throw ServiceDiscoveryError.unsafeEndpoint
        }

        let endpoint = ServiceEndpoint(baseURL: url)
        let connection = ServiceConnection(
            connectionID: connectionID,
            endpoint: endpoint,
            credentialCapability: RegistrationCredentialCapability(registration: registration, connectionID: connectionID)
        )
        let request = HTTPRequest(method: .get, relativePath: "/api/info")
        let response: HTTPResponse
        do {
            response = try await transport.send(connection: connection, request: request)
        } catch is CancellationError { throw CancellationError() }
        catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw ServiceDiscoveryError.unauthorized
            case .backend: throw ServiceDiscoveryError.unexpectedStatus
            default: throw ServiceDiscoveryError.requestFailed
            }
        } catch { throw ServiceDiscoveryError.requestFailed }

        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw ServiceDiscoveryError.unauthorized }
            throw ServiceDiscoveryError.unexpectedStatus
        }
        let info = try ServerInfo.decode(response.body)
        guard info.pid == registration.pid else { throw ServiceDiscoveryError.processMismatch }
        if let registeredVersion = registration.version, registeredVersion != info.version {
            throw ServiceDiscoveryError.versionMismatch
        }
        if case let .exact(expected) = version, expected != info.version {
            throw ServiceDiscoveryError.versionMismatch
        }
        return LocalServiceConnection(connection: connection, registration: registration, info: info)
    }

    private func isSafeLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host else { return false }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.dropFirst().allSatisfy {
            guard let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }
}
