import Foundation

enum ServiceDiscoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case registrationMissing
    case registrationUnreadable
    case registrationMalformed
    case registrationPermissions
    case unsafeEndpoint
    case requestFailed
    case unauthorized
    case unexpectedStatus
    case malformedServerInfo
    case processMismatch
    case versionMismatch

    var description: String {
        switch self {
        case .registrationMissing: return "local service registration is unavailable"
        case .registrationUnreadable: return "local service registration could not be read"
        case .registrationMalformed: return "local service registration is malformed"
        case .registrationPermissions: return "local service registration permissions are insecure"
        case .unsafeEndpoint: return "local service endpoint is not allowed"
        case .requestFailed: return "local service probe failed"
        case .unauthorized: return "local service probe was unauthorized"
        case .unexpectedStatus: return "local service probe returned an unexpected status"
        case .malformedServerInfo: return "local service returned malformed information"
        case .processMismatch: return "local service process is stale"
        case .versionMismatch: return "local service version does not match"
        }
    }
}

struct ServiceRegistration: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let url: String
    let pid: Int
    let id: String?
    let version: String?
    let password: String?

    var description: String { "ServiceRegistration(<redacted>)" }

    var debugDescription: String { "ServiceRegistration(<redacted>)" }

    var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>(), displayStyle: .struct)
    }

    static func decode(_ data: Data) throws -> ServiceRegistration {
        do {
            let value = try JSONDecoder().decode(ServiceRegistration.self, from: data)
            guard !value.url.isEmpty, value.pid > 0 else { throw ServiceDiscoveryError.registrationMalformed }
            return value
        } catch let error as ServiceDiscoveryError { throw error }
        catch { throw ServiceDiscoveryError.registrationMalformed }
    }
}

enum ServiceRegistrationPath {
    /// Pure path resolution. Callers must provide HOME explicitly when XDG_STATE_HOME is absent.
    static func resolve(environment: [String: String], homeDirectory: URL? = nil) -> URL? {
        let state = environment["XDG_STATE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL?
        if let state, !state.isEmpty {
            root = URL(fileURLWithPath: state, isDirectory: true)
        } else if let homeDirectory {
            root = homeDirectory.appendingPathComponent(".local/state", isDirectory: true)
        } else {
            root = nil
        }
        return root?.appendingPathComponent("opencode/service.json", isDirectory: false)
    }
}

struct LocalServiceRegistrationReader: @unchecked Sendable {
    let fileURL: URL
    let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func read() throws -> ServiceRegistration {
        guard fileManager.fileExists(atPath: fileURL.path) else { throw ServiceDiscoveryError.registrationMissing }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode == 0o600 else {
                throw ServiceDiscoveryError.registrationPermissions
            }
            return try ServiceRegistration.decode(Data(contentsOf: fileURL))
        } catch let error as ServiceDiscoveryError { throw error }
        catch { throw ServiceDiscoveryError.registrationUnreadable }
    }
}

struct RegistrationCredentialCapability: CredentialCapability, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let connectionID: ConnectionID
    private let password: String?

    init(registration: ServiceRegistration, connectionID: ConnectionID) {
        self.connectionID = connectionID
        self.password = registration.password
    }

    var safeDescription: String { "registration credentials (secret redacted)" }

    var description: String { "RegistrationCredentialCapability(<redacted>)" }

    var debugDescription: String { "RegistrationCredentialCapability(<redacted>)" }

    var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>(), displayStyle: .struct)
    }

    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        try Task.checkCancellation()
        guard connection == connectionID, let password else { return nil }
        return ServiceCredential(username: "opencode", password: password)
    }
}
