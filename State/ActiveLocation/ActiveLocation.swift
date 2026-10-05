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

enum ActiveLocationState: Equatable, Sendable {
    case empty
    case selected(directory: URL)
    case resolving(directory: URL)
    case resolved(ResolvedLocation)
    case needsRecovery(directory: URL?, problem: ActiveLocationProblem)
}
