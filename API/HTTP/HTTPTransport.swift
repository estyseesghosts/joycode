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
///
/// The transport owns a single URLSession for its lifetime. Sessions are
/// application-scoped: JoycodeApp constructs one production transport and
/// composition forwards it, so sequential requests never construct sessions.
final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    let timeout: TimeInterval
    private let session: URLSession
    private let redirectDelegate: RedirectPolicy

    init(
        timeout: TimeInterval = 30,
        urlProtocolClasses: [AnyClass] = [],
        sessionFactory: (@Sendable (URLSessionConfiguration, URLSessionDelegate?) -> URLSession)? = nil
    ) {
        self.timeout = timeout
        let redirectDelegate = RedirectPolicy()
        self.redirectDelegate = redirectDelegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = urlProtocolClasses
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let sessionFactory {
            self.session = sessionFactory(configuration, redirectDelegate)
        } else {
            self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        }
    }

    deinit { session.invalidateAndCancel() }

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        let (urlRequest, _) = try await HTTPRequestBuilder.makeRequest(connection: connection, request: request, timeout: timeout)

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
    static func shouldFollow() -> Bool { false }
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    override init() { super.init() }

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
        _ = HTTPRedirectPolicy.shouldFollow()
        completionHandler(nil)
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
