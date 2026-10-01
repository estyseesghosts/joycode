import Foundation

/// An opaque identifier used by OpenCode's project resources.
struct ProjectID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

/// An opaque identifier used by OpenCode's session resources.
struct SessionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

/// Identifies a configured logical connection, not a server process or stream generation.
struct ConnectionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

struct LocationID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

struct WorkspaceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

struct WorktreeID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}

/// A Joycode relationship to a parent session; it is not a SessionID alias.
struct ParentSessionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(_ sessionID: SessionID) { rawValue = sessionID.rawValue }

    var sessionID: SessionID { SessionID(rawValue: rawValue) }
}

struct TabID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
}
