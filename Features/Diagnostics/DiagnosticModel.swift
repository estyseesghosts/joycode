import Foundation

typealias DiagnosticStatus = ServiceConnectionStatus

/// Compatibility name for the initial diagnostic screen. Event consumption belongs to R02.
@MainActor
final class DiagnosticModel: ServiceConnectionOwner {
    override init(discover: @escaping ServiceConnectionDiscovery, timeout: Duration = .seconds(30)) {
        super.init(discover: discover, timeout: timeout)
    }
}
