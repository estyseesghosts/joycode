import Foundation

/// Production wiring is deliberately lazy: constructing the composition does not
/// resolve registration, touch the filesystem, or create a URLSession.
enum DiagnosticComposition {
    @MainActor
    static func productionModel(version: ServiceVersionRequirement = .exact("2.0.20")) -> DiagnosticModel {
        DiagnosticModel(
            discover: {
                let environment = ProcessInfo.processInfo.environment
                guard let path = ServiceRegistrationPath.resolve(
                    environment: environment,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ) else { throw ServiceDiscoveryError.registrationMissing }
                let discovery = LocalServiceDiscovery(
                    registrationReader: LocalServiceRegistrationReader(fileURL: path),
                    transport: URLSessionHTTPTransport()
                )
                return try await discovery.discover(version: version)
            },
        )
    }
}
