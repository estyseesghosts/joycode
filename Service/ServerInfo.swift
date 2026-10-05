import Foundation

struct ServerInfo: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let version: String
    let pid: Int
    let urls: [String]
    let paths: Paths

    var description: String { "ServerInfo(<redacted>)" }

    var debugDescription: String { "ServerInfo(<redacted>)" }

    var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<(label: String?, value: Any)>(), displayStyle: .struct)
    }

    struct Paths: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let tmp: String

        var description: String { "ServerInfo.Paths(<redacted>)" }

        var debugDescription: String { "ServerInfo.Paths(<redacted>)" }

        var customMirror: Mirror {
            Mirror(self, children: EmptyCollection<(label: String?, value: Any)>(), displayStyle: .struct)
        }
    }

    static func decode(_ data: Data) throws -> ServerInfo {
        do {
            let info = try JSONDecoder().decode(ServerInfo.self, from: data)
            guard info.pid >= 0 else { throw ServiceDiscoveryError.malformedServerInfo }
            return info
        } catch let error as ServiceDiscoveryError { throw error }
        catch { throw ServiceDiscoveryError.malformedServerInfo }
    }
}
