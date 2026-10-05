import Foundation

struct SessionInfo: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let parentID: String?
    let projectID: String
    let title: String?
    let location: LocationRef

    var description: String { "SessionInfo(<redacted>)" }
    var debugDescription: String { description }

    enum CodingKeys: String, CodingKey { case id, parentID, projectID, title, location }
    static func decode(_ data: Data) throws -> SessionInfo {
        do { return try JSONDecoder().decode(SessionInfo.self, from: data) }
        catch { throw SessionAPIError.malformedResponse }
    }
}

struct LocationRef: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let directory: String
    var description: String { "LocationRef(<redacted>)" }
    var debugDescription: String { description }
}

struct SessionEnvelope: Decodable, Equatable, Sendable {
    let data: SessionInfo
    static func decode(_ data: Data) throws -> SessionEnvelope {
        do { return try JSONDecoder().decode(SessionEnvelope.self, from: data) }
        catch { throw SessionAPIError.malformedResponse }
    }
}

struct Cursor: Decodable, Equatable, Sendable {
    let previous: String?
    let next: String?
}

struct SessionListEnvelope: Decodable, Equatable, Sendable {
    let data: [SessionInfo]
    let cursor: Cursor
    static func decode(_ data: Data) throws -> SessionListEnvelope {
        do { return try JSONDecoder().decode(SessionListEnvelope.self, from: data) }
        catch { throw SessionAPIError.malformedResponse }
    }
}
