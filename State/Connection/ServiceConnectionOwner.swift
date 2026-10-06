import Foundation
import Combine

typealias ServiceConnectionDiscovery = @Sendable () async throws -> LocalServiceConnection

enum ServiceConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(version: String)
    case unauthorized
    case incompatible
    case failure
}

/// The single application-owned handoff point for the passive service connection.
/// It only reads registration metadata and probes GET /api/info; it never manages the
/// lifetime of the server.
struct ServiceConnectionContext: Sendable {
    let connection: ServiceConnection
    let version: String
    let generation: UInt64
}

@MainActor
class ServiceConnectionOwner: ObservableObject {
    @Published private(set) var status: ServiceConnectionStatus = .disconnected
    @Published private(set) var currentContext: ServiceConnectionContext?

    private let discover: ServiceConnectionDiscovery
    private let timeout: Duration
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(discover: @escaping ServiceConnectionDiscovery, timeout: Duration = .seconds(30)) {
        self.discover = discover
        self.timeout = timeout
    }

    func connect() {
        generation &+= 1
        let attempt = generation
        operation?.cancel()
        currentContext = nil
        status = .connecting
        operation = Task { [weak self] in
            guard let self else { return }
            // Release the finished task only while this attempt still owns the generation.
            defer { if generation == attempt { operation = nil } }
            do {
                let result = try await Self.withTimeout(self.timeout) { [discover = self.discover] in
                    try await discover()
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                let version = Self.safeVersion(result.info.version)
                currentContext = ServiceConnectionContext(
                    connection: result.connection,
                    version: version,
                    generation: attempt
                )
                status = .connected(version: version)
            } catch is CancellationError {
                // Cancellation is an intentional disconnect or superseded attempt.
            } catch let error as ServiceDiscoveryError {
                guard generation == attempt else { return }
                currentContext = nil
                switch error {
                case .unauthorized: status = .unauthorized
                case .versionMismatch, .malformedServerInfo: status = .incompatible
                default: status = .failure
                }
            } catch {
                guard generation == attempt else { return }
                currentContext = nil
                status = .failure
            }
        }
    }

    func disconnect() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        currentContext = nil
        status = .disconnected
    }

    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ServiceConnectionTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func safeVersion(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e }
        let limited = String(String.UnicodeScalarView(scalars)).prefix(80)
        return limited.isEmpty ? "Unknown" : String(limited)
    }
}

private struct ServiceConnectionTimeout: Error {}
