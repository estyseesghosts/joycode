import Foundation

/// Failures at the HTTP boundary. HTTP status failures are deliberately not retryable:
/// mutation policy belongs to the application/service layer.
enum HTTPTransportError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unauthorized
    case backend(statusCode: Int)
    case protocolError(String)
    case transport(String)
    case credentialUnavailable
    case redirectRejected
}

/// Foundation URLSession transport for the frozen, V2-agnostic HTTP contracts.
struct URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    var timeout: TimeInterval
    private var urlProtocolClasses: [AnyClass]

    init(timeout: TimeInterval = 30, urlProtocolClasses: [AnyClass] = []) {
        self.timeout = timeout
        self.urlProtocolClasses = urlProtocolClasses
    }

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        let (urlRequest, url) = try await HTTPRequestBuilder.makeRequest(connection: connection, request: request, timeout: timeout)

        let delegate = RedirectPolicy(initialURL: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = urlProtocolClasses
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPTransportError.protocolError("response was not HTTP")
            }
            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String { result[key] = String(describing: item.value) }
            }
            switch httpResponse.statusCode {
            case 200..<300:
                return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
            case 401:
                throw HTTPTransportError.unauthorized
            case 300..<400:
                // Redirects are never exposed as successful responses. The
                // delegate rejects every redirect, including same-origin ones.
                throw HTTPTransportError.redirectRejected
            case 400..<600:
                throw HTTPTransportError.backend(statusCode: httpResponse.statusCode)
            default:
                throw HTTPTransportError.protocolError("unsupported HTTP status \(httpResponse.statusCode)")
            }
        } catch let error as HTTPTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw HTTPTransportError.redirectRejected
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let urlError = error as? URLError {
                throw HTTPTransportError.transport("urlError:\(urlError.code.rawValue)")
            }
            throw HTTPTransportError.transport("unknown")
        }
    }

}

/// Redirects are deliberately never followed. OpenCode credentials must not be
/// sent to a location selected by an HTTP response.
enum HTTPRedirectPolicy {
    static func shouldFollow(from: URL, to: URL) -> Bool { false }
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let initialURL: URL

    init(initialURL: URL) { self.initialURL = initialURL }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Do not follow even same-origin redirects: the response is mapped to
        // redirectRejected by the transport rather than exposing a redirect as
        // a successful response or risking credential leakage.
        let shouldFollow = request.url.map {
            HTTPRedirectPolicy.shouldFollow(from: initialURL, to: $0)
        } ?? false
        completionHandler(shouldFollow ? request : nil)
    }
}

enum HTTPJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw HTTPTransportError.protocolError("could not encode JSON") }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw HTTPTransportError.protocolError("malformed JSON response") }
    }
}
