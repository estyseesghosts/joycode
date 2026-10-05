import Foundation

struct LocationPublicInfo: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let directory: String
    let project: Project

    struct Project: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let id: String
        let directory: String
        let canonical: String

        var description: String { "LocationPublicInfo.Project(id: <redacted>, directory: <redacted>, canonical: <redacted>)" }
        var debugDescription: String { description }
    }

    var description: String { "LocationPublicInfo(directory: <redacted>, project: <redacted>)" }
    var debugDescription: String { description }

    static func decode(_ data: Data) throws -> LocationPublicInfo {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw LocationResolutionError.malformedResponse }
    }
}
