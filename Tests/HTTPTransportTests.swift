import Foundation
import XCTest
@testable import Joycode

final class HTTPTransportTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.responseHandler = nil
        URLProtocolStub.requestURLs = []
        URLProtocolStub.capturedRequests = []
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
        XCTAssertFalse(HTTPRedirectPolicy.shouldFollow())
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

        RedirectPolicy().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination)
        ) { completionRequest = $0 }

        XCTAssertNil(completionRequest)
    }

    func testRedirectResponseMapsToRedirectRejectedWithoutFollowing() async throws {
        URLProtocolStub.handler = { _ in (302, Data(), ["Location": "http://localhost/root/other"]) }
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        do {
            _ = try await transport.send(connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api"))
            XCTFail("expected redirect rejection")
        } catch let error as HTTPTransportError {
            XCTAssertEqual(error, .redirectRejected)
        }
        XCTAssertEqual(URLProtocolStub.capturedRequests.count, 1)
    }

    func testSingleSessionServesManySequentialRequests() async throws {
        URLProtocolStub.handler = { _ in (200, Data("{}".utf8), [:]) }
        let counter = SessionFactoryCounter()
        let transport = URLSessionHTTPTransport(
            urlProtocolClasses: [URLProtocolStub.self],
            sessionFactory: { configuration, delegate in
                counter.make(configuration: configuration, delegate: delegate)
            }
        )
        for _ in 0..<120 {
            let response = try await transport.send(
                connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/info"))
            XCTAssertEqual(response.statusCode, 200)
        }
        XCTAssertEqual(counter.currentCount(), 1)
    }

    func testDistinctConnectionsKeepSeparateAuthorizationHeaders() async throws {
        URLProtocolStub.handler = { _ in (200, Data(), [:]) }
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        func makeConnection(user: String, password: String, id: String) -> ServiceConnection {
            ServiceConnection(
                connectionID: ConnectionID(rawValue: id),
                endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost/root")!),
                credentialCapability: NamedCredentials(username: user, password: password)
            )
        }
        let connectionA = makeConnection(user: "alice", password: "secret-a", id: "a")
        let connectionB = makeConnection(user: "bob", password: "secret-b", id: "b")
        _ = try await transport.send(connection: connectionA, request: HTTPRequest(method: .get, relativePath: "/api"))
        _ = try await transport.send(connection: connectionB, request: HTTPRequest(method: .get, relativePath: "/api"))
        _ = try await transport.send(connection: connectionA, request: HTTPRequest(method: .get, relativePath: "/api"))
        let headers = URLProtocolStub.capturedRequests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(headers.count, 3)
        let expectedA = "Basic " + Data("alice:secret-a".utf8).base64EncodedString()
        let expectedB = "Basic " + Data("bob:secret-b".utf8).base64EncodedString()
        XCTAssertEqual(headers[0], expectedA)
        XCTAssertEqual(headers[1], expectedB)
        XCTAssertEqual(headers[2], expectedA)
        XCTAssertNotEqual(headers[0], headers[1])
    }

    func testSetCookieIsNotPropagatedAcrossRequests() async throws {
        URLProtocolStub.handler = { _ in (200, Data(), ["Set-Cookie": "session=abc; Path=/"]) }
        let transport = URLSessionHTTPTransport(urlProtocolClasses: [URLProtocolStub.self])
        _ = try await transport.send(connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/one"))
        _ = try await transport.send(connection: connection(), request: HTTPRequest(method: .get, relativePath: "/api/two"))
        XCTAssertEqual(URLProtocolStub.capturedRequests.count, 2)
        for captured in URLProtocolStub.capturedRequests {
            XCTAssertNil(captured.value(forHTTPHeaderField: "Cookie"))
        }
    }

    func testProductionAPIsHoldInjectedTransportInstance() {
        let spy = SpyTransport()
        XCTAssertEqual(ObjectIdentifier(SessionAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(SelectionAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(ExecutionAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(PermissionAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(PromptAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(TranscriptAPI(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        XCTAssertEqual(ObjectIdentifier(LocationResolver(transport: spy).transport as! SpyTransport), ObjectIdentifier(spy))
        let discovery = LocalServiceDiscovery(
            registrationReader: LocalServiceRegistrationReader(fileURL: URL(fileURLWithPath: "/tmp/joycode-h01-nonexistent.json")),
            transport: spy
        )
        XCTAssertEqual(ObjectIdentifier(discovery.transport as! SpyTransport), ObjectIdentifier(spy))
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

private struct NamedCredentials: CredentialCapability {
    let username: String
    let password: String
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        ServiceCredential(username: username, password: password)
    }
}

private final class SessionFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func make(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?) -> URLSession {
        lock.lock()
        count += 1
        lock.unlock()
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    func currentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class SpyTransport: HTTPTransport, @unchecked Sendable {
    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data())
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, [String: String])?)?
    nonisolated(unsafe) static var responseHandler: ((URLRequest) -> URLResponse?)?
    nonisolated(unsafe) static var requestURLs: [URL] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.requestURLs.append(url) }
        Self.capturedRequests.append(request)
        if let response = Self.responseHandler?(request) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let result = Self.handler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: result.2)!
        // Deliver 3xx (including Location) as an ordinary response. The
        // transport maps any 3xx to redirectRejected and the session delegate
        // denies any redirect the stack itself attempts. Synthesizing
        // wasRedirectedTo here would hang inside Foundation regardless of the
        // delegate decision, so the stub must not use that path.
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
