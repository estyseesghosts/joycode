import Foundation
import XCTest
@testable import Joycode

final class HTTPTransportTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseHandler = nil
        URLProtocolStub.requestURLs = []
        super.tearDown()
    }

    func testBuildsEndpointPathQueryBodyAndBasicAuthentication() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/root/api/search")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queryItems?.map(\.name), ["location[directory]", "q"])
            XCTAssertEqual(queryItems?.map(\.value), ["/tmp/✓", "a b"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic YWxpY2U6c2VjcmV0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(readBody(from: request), Data("{\"ok\":true}".utf8))
            return (200, Data("{}".utf8), [:])
        }
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        let response = try await transport.send(
            connection: connection(),
            request: HTTPRequest(method: .post, relativePath: "/api/search", queryItems: [
                HTTPQueryItem(name: "location[directory]", value: "/tmp/✓"),
                HTTPQueryItem(name: "q", value: "a b")
            ], body: Data("{\"ok\":true}".utf8))
        )
        XCTAssertEqual(response.statusCode, 200)
    }

    func testMapsUnauthorizedAndBackendStatusWithoutRetry() async throws {
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        URLProtocolStub.handler = { _ in (401, Data(), [:]) }
        do {
            _ = try await transport.send(connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/info"))
            XCTFail("expected unauthorized")
        } catch let error as HTTPTransportError { XCTAssertEqual(error, .unauthorized) }

        URLProtocolStub.handler = { _ in (503, Data(), [:]) }
        do {
            _ = try await transport.send(connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/info"))
            XCTFail("expected backend failure")
        } catch let error as HTTPTransportError { XCTAssertEqual(error, .backend(statusCode: 503)) }
    }

    func testRejectsAbsoluteAndTraversalPaths() async throws {
        for path in ["https://other.test/api", "/api/../secret", "/api/%2e%2e/secret", "/api/%ZZ", "//other/api"] {
            do {
                _ = try await URLSessionHTTPTransport().send(connection: connection(), request: HTTPRequest(method: .get, relativePath: path))
                XCTFail("expected rejection for \(path)")
            } catch let error as HTTPTransportError {
                guard case .invalidRequest = error else { XCTFail("wrong error: \(error)"); continue }
            }
        }
    }

    func testRejectsNonLoopbackHTTPBeforeRequestingCredentials() async throws {
        let credentials = CountingCredentials()
        let connection = ServiceConnection(
            connectionID: ConnectionID(rawValue: "test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://remote.test/root")!),
            credentialCapability: credentials
        )
        do {
            _ = try await URLSessionHTTPTransport().send(connection: connection, request: HTTPRequest(method: .get, relativePath: "/api"))
            XCTFail("expected plaintext HTTP rejection")
        } catch let error as HTTPTransportError {
            guard case .invalidRequest = error else { XCTFail("wrong error: \(error)"); return }
        }
        let requestCount = await credentials.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testJoinsRootAndTrailingSlashEndpointPaths() async throws {
        for (base, expected) in [("http://localhost", "/api"), ("http://localhost/", "/api"), ("http://localhost/root/", "/root/api")] {
            URLProtocolStub.handler = { request in
                XCTAssertEqual(request.url?.path, expected)
                return (200, Data(), [:])
            }
            _ = try await URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self]).send(
                connection: connection(baseURL: base), request: HTTPRequest(method: .get, relativePath: "/api"))
        }
    }

    func testPreservesEscapedPathSegment() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/root/api/id%2Fpart")
            return (200, Data(), [:])
        }
        _ = try await URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self]).send(
            connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/id%2Fpart"))
    }

    func testSanitizesCredentialCapabilityFailure() async throws {
        let sentinel = "credential-secret-sentinel"
        do {
            _ = try await URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self]).send(
                connection: ServiceConnection(
                    connectionID: ConnectionID(rawValue: "test"),
                    endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost/root")!),
                    credentialCapability: FailingCredentials(message: sentinel)),
                request: HTTPRequest(method: .get, relativePath: "/api"))
            XCTFail("expected credential failure")
        } catch {
            XCTAssertEqual(error as? HTTPTransportError, .credentialUnavailable)
            XCTAssertFalse(String(describing: error).contains(sentinel))
        }
    }

    func testMalformedJSONIsProtocolError() {
        do {
            _ = try HTTPJSON.decode([String: String].self, from: Data("not-json".utf8))
            XCTFail("expected malformed JSON")
        } catch let error as HTTPTransportError {
            XCTAssertEqual(error, .protocolError("malformed JSON response"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNonHTTPResponseIsProtocolError() async throws {
        URLProtocolStub.responseHandler = { request in
            URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        do {
            _ = try await URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self]).send(
                connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api"))
            XCTFail("expected non-HTTP response failure")
        } catch let error as HTTPTransportError {
            XCTAssertEqual(error, .protocolError("response was not HTTP"))
        }
    }

    func testCancellationProducesCancellationError() async throws {
        let started = expectation(description: "request started")
        URLProtocolStub.handler = { _ in
            started.fulfill()
            return nil
        }
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        let serviceConnection = connection()
        let request = HTTPRequest(method: .get, relativePath: "/api")
        let task = Task {
            try await transport.send(connection: serviceConnection, request: request)
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationDuringCredentialLookupDoesNotCreateRequest() async throws {
        let credentials = GatedCredentials()
        let serviceConnection = ServiceConnection(
            connectionID: ConnectionID(rawValue: "test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost/root")!),
            credentialCapability: credentials
        )
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        let task = Task {
            try await transport.send(
                connection: serviceConnection,
                request: HTTPRequest(method: .post, relativePath: "/api/mutate", body: Data("{}".utf8))
            )
        }

        await credentials.waitUntilLookupStarted()
        task.cancel()
        await credentials.resolve(nil)

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(URLProtocolStub.requestURLs.isEmpty)
    }

    func testRedirectPolicyRejectsAllRedirects() {
        let source = URL(string: "https://example.test/api")!
        let destination = URL(string: "https://example.test/other")!
        XCTAssertFalse(HTTPRedirectPolicy.shouldFollow(from: source, to: destination))
        XCTAssertFalse(HTTPRedirectPolicy.shouldFollow(
            from: source, to: URL(string: "https://other.test/api")!))
    }

    func testRedirectDelegateRejectsCrossOriginRedirect() {
        let source = URL(string: "https://example.test/api")!
        let destination = URL(string: "https://other.test/api")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: source)
        let response = HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        )!
        var completionRequest: URLRequest?

        RedirectPolicy(initialURL: source).urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination)
        ) { completionRequest = $0 }

        XCTAssertNil(completionRequest)
    }

    private func connection(baseURL: String = "http://localhost/root") -> ServiceConnection {
        ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: baseURL)!), credentialCapability: Credentials())
    }
}

private actor CountingCredentials: CredentialCapability {
    var requestCount = 0
    nonisolated var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        requestCount += 1
        return nil
    }
}

private actor GatedCredentials: CredentialCapability {
    private var lookupStarted = false
    private var lookupWaiter: CheckedContinuation<Void, Never>?
    private var credentialContinuation: CheckedContinuation<ServiceCredential?, Never>?

    nonisolated var safeDescription: String { "test" }

    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        lookupStarted = true
        lookupWaiter?.resume()
        lookupWaiter = nil
        return await withCheckedContinuation { continuation in
            credentialContinuation = continuation
        }
    }

    func waitUntilLookupStarted() async {
        if lookupStarted { return }
        await withCheckedContinuation { continuation in
            lookupWaiter = continuation
        }
    }

    func resolve(_ credential: ServiceCredential?) {
        credentialContinuation?.resume(returning: credential)
        credentialContinuation = nil
    }
}

private struct Credentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { ServiceCredential(username: "alice", password: "secret") }
}

private struct FailingCredentials: CredentialCapability {
    let message: String
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        struct Failure: Error { let message: String }
        throw Failure(message: message)
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, [String: String])?)?
    nonisolated(unsafe) static var responseHandler: ((URLRequest) -> URLResponse?)?
    nonisolated(unsafe) static var requestURLs: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.requestURLs.append(url) }
        if let response = Self.responseHandler?(request) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let result = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: result.2)!
        if (300..<400).contains(result.0), let location = result.2["Location"],
           let redirectedURL = URL(string: location, relativeTo: request.url)?.absoluteURL {
            var redirectedRequest = request
            redirectedRequest.url = redirectedURL
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

}

private func readBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
