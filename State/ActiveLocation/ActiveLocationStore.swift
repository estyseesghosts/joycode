import Foundation
import Combine

@MainActor
final class ActiveLocationStore: ObservableObject {
    @Published private(set) var state: ActiveLocationState = .empty
    var activeLocation: ResolvedLocation? { if case .resolved(let value) = state { return value }; return nil }

    private let preferences: LocalPreferencesStore
    private let availability: @Sendable (URL) -> DirectoryAvailability
    private let resolve: @Sendable (URL) async throws -> ResolvedLocation
    private var operation: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        preferences: LocalPreferencesStore,
        availability: @escaping @Sendable (URL) -> DirectoryAvailability = { ActiveLocationStore.defaultAvailability($0) },
        resolve: @escaping @Sendable (URL) async throws -> ResolvedLocation
    ) {
        self.preferences = preferences; self.availability = availability; self.resolve = resolve
    }

    func restore() {
        do {
            guard let directory = try preferences.load().selectedDirectory else { state = .empty; return }
            beginVerification(directory)
        } catch { state = .needsRecovery(directory: nil, problem: .preferencesUnreadable) }
    }

    func select(_ directory: URL) {
        if var prefs = try? preferences.load() { prefs.selectedDirectory = directory; try? preferences.save(prefs) }
        beginVerification(directory)
    }

    func retry() {
        switch state {
        case .selected(let directory), .resolving(let directory): beginVerification(directory)
        case .needsRecovery(let directory, _): if let directory { beginVerification(directory) }
        default: break
        }
    }

    func clear() {
        generation &+= 1; operation?.cancel(); operation = nil
        if var prefs = try? preferences.load() { prefs.selectedDirectory = nil; try? preferences.save(prefs) }
        state = .empty
    }

    private func beginVerification(_ directory: URL) {
        generation &+= 1; let attempt = generation
        operation?.cancel()
        switch availability(directory) {
        case .missing: state = .needsRecovery(directory: directory, problem: .directoryMissing); return
        case .notADirectory: state = .needsRecovery(directory: directory, problem: .notADirectory); return
        case .inaccessible: state = .needsRecovery(directory: directory, problem: .directoryInaccessible); return
        case .directory: break
        }
        state = .resolving(directory: directory)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await resolve(directory)
                guard generation == attempt else { return }
                let currentAvailability = availability(directory)
                guard generation == attempt else { return }
                switch currentAvailability {
                case .directory: state = .resolved(result)
                case .missing: state = .needsRecovery(directory: directory, problem: .directoryMissing)
                case .notADirectory: state = .needsRecovery(directory: directory, problem: .notADirectory)
                case .inaccessible: state = .needsRecovery(directory: directory, problem: .directoryInaccessible)
                }
            } catch is CancellationError { } catch let error as LocationResolutionError {
                guard generation == attempt else { return }
                switch error {
                case .notConnected: state = .selected(directory: directory)
                case .unauthorized: state = .needsRecovery(directory: directory, problem: .unauthorized)
                case .malformedResponse: state = .needsRecovery(directory: directory, problem: .malformedResponse)
                case .backend, .requestFailed: state = .needsRecovery(directory: directory, problem: .requestFailed)
                }
            } catch {
                guard generation == attempt else { return }
                state = .needsRecovery(directory: directory, problem: .requestFailed)
            }
        }
    }

    nonisolated static func defaultAvailability(_ directory: URL) -> DirectoryAvailability {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notADirectory }
        guard FileManager.default.isReadableFile(atPath: directory.path), FileManager.default.isExecutableFile(atPath: directory.path) else { return .inaccessible }
        return .directory
    }
}
