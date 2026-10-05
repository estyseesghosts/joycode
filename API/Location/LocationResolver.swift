import Foundation

enum LocationResolutionError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case backend(statusCode: Int)
    case malformedResponse
    case requestFailed
}

struct LocationResolver: Sendable {
    let transport: any HTTPTransport

    static func request(directory: URL) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            relativePath: "/api/location",
            queryItems: [HTTPQueryItem(name: "location[directory]", value: directory.path)]
        )
    }

    func resolve(connection: ServiceConnection, directory: URL) async throws -> LocationPublicInfo {
        let request = Self.request(directory: directory)
        do {
            let response = try await transport.send(connection: connection, request: request)
            guard (200..<300).contains(response.statusCode) else {
                throw LocationResolutionError.backend(statusCode: response.statusCode)
            }
            return try LocationPublicInfo.decode(response.body)
        } catch is CancellationError { throw CancellationError() }
        catch let error as LocationResolutionError { throw error }
        catch let error as HTTPTransportError {
            switch error {
            case .unauthorized: throw LocationResolutionError.unauthorized
            case .backend(let statusCode): throw LocationResolutionError.backend(statusCode: statusCode)
            default: throw LocationResolutionError.requestFailed
            }
        } catch { throw LocationResolutionError.requestFailed }
    }
}
