import Foundation

struct ProjectIdentity: Equatable, Sendable {
    let id: ProjectID
    let directory: URL
    let canonical: URL
}

struct ResolvedLocation: Equatable, Sendable {
    let directory: URL
    let project: ProjectIdentity
}

enum DirectoryAvailability: Equatable, Sendable { case directory, missing, notADirectory, inaccessible }

enum ActiveLocationProblem: Equatable, Sendable {
    case directoryMissing, notADirectory, directoryInaccessible, notConnected, unauthorized, requestFailed, malformedResponse, preferencesUnreadable
}

/// Non-blocking warning that the chosen folder was not durably saved. It is
/// overlay state: the running selection stays usable regardless.
enum LocationPersistenceProblem: Equatable, Sendable {
    case loadFailed, saveFailed
}

enum ActiveLocationState: Equatable, Sendable {
    case empty
    case selected(directory: URL)
    case resolving(directory: URL)
    case resolved(ResolvedLocation)
    case needsRecovery(directory: URL?, problem: ActiveLocationProblem)
}
