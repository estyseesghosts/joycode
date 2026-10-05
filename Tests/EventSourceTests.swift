import Foundation
import XCTest
@testable import Joycode

final class EventSourceTests: XCTestCase {
    override func tearDown() {
        EventSourceURLProtocol.handler = nil
        EventSourceURLProtocol.statusHandler = nil
        EventSourceURLProtocol.streamHandler = nil
        EventSourceURLProtocol.stopHandler = nil
        EventSourceURLProtocol.finishHandler = nil
        super.tearDown()
    }

    func testParserHandlesUnicodeSplitAcrossChunksAndComments() throws {
        var parser = SSEParser()
        let wire = Data(": heartbeat\r\n\r\ndata: {\"id\":\"1\",\"type\":\"server.connected\",\"data\":{}}\r\n\r\n".utf8)
        var events = [EventEnvelope]()
        for byte in wire { events += try parser.append(Data([byte])) }
        XCTAssertEqual(events.first?.type, "server.connected")
        XCTAssertNil(events.first?.created)

        var unicodeParser = SSEParser()
        let unicode = Data("data: {\"id\":\"é\",\"type\":\"x\",\"created\":1,\"data\":{}}\n\n".utf8)
        var unicodeEvents = [EventEnvelope]()
        for byte in unicode { unicodeEvents += try unicodeParser.append(Data([byte])) }
        XCTAssertEqual(unicodeEvents.first?.id, "é")
    }

    func testParserCombinesDataLinesAndRejectsOversizedEvents() throws {
        var parser = SSEParser(maxEventBytes: 20)
        XCTAssertThrowsError(try parser.append(Data("data: {\"id\":\"1\",\"type\":\"x\",\"created\":1,\"data\":{}\n".utf8))) { error in
            XCTAssertEqual(error as? SSEParserError, .eventTooLarge)
        }
        var valid = SSEParser()
        var events = try valid.append(Data("data: {\"id\":\"1\",\n".utf8))
        events += try valid.append(Data("data: \"type\":\"x\",\"created\":1,\"data\":{}}\n\n".utf8))
        XCTAssertEqual(events.count, 1)
    }

    func testMalformedJSONFailsExplicitly() {
        var parser = SSEParser()
        XCTAssertThrowsError(try parser.append(Data("data: not-json\n\n".utf8))) { error in
            XCTAssertEqual(error as? SSEParserError, .malformedJSON)
        }
    }

    func testFinishRejectsEventWithoutBlankLineFrameDelimiter() throws {
        var parser = SSEParser()
        XCTAssertTrue(try parser.append(Data("data: {\"id\":\"1\",\"type\":\"x\",\"created\":1,\"data\":{}}\n".utf8)).isEmpty)
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertEqual(error as? SSEParserError, .unterminatedFrame)
        }
    }

    func testEventSourceBuildsAuthenticatedSSERequestAndParsesEvent() async throws {
        EventSourceURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            return (200, Data("data: {\"id\":\"1\",\"type\":\"server.connected\",\"data\":{}}\n\n".utf8), ["Content-Type": "text/event-stream; charset=utf-8"])
        }

        let source = URLSessionEventSource(urlProtocolClasses: [EventSourceURLProtocol.self])
        let stream = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.id, "1")
        XCTAssertEqual(event?.type, "server.connected")
    }

    func testEventSourceRejectsNonSuccessfulResponseAndContentType() async throws {
        EventSourceURLProtocol.statusHandler = { _ in
            (503, Data(), ["Content-Type": "text/event-stream"])
        }
        let source = URLSessionEventSource(urlProtocolClasses: [EventSourceURLProtocol.self])

        do {
            _ = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
            XCTFail("expected HTTP status failure")
        } catch let error as EventSourceError {
            XCTAssertEqual(error, .httpStatus(503))
        }

        EventSourceURLProtocol.statusHandler = { _ in
            (200, Data(), ["Content-Type": "application/json"])
        }
        do {
            _ = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
            XCTFail("expected content type failure")
        } catch let error as EventSourceError {
            XCTAssertEqual(error, .invalidContentType)
        }

        EventSourceURLProtocol.statusHandler = { _ in
            (401, Data(), ["Content-Type": "text/event-stream"])
        }
        do {
            _ = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
            XCTFail("expected unauthorized failure")
        } catch let error as EventSourceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testEventSourceRejectsNoContentAndUnexpectedSuccessfulStatus() async throws {
        let source = URLSessionEventSource(urlProtocolClasses: [EventSourceURLProtocol.self])

        for status in [204, 206] {
            EventSourceURLProtocol.statusHandler = { _ in
                (status, Data(), ["Content-Type": "text/event-stream"])
            }

            do {
                _ = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
                XCTFail("expected HTTP status failure for \(status)")
            } catch let error as EventSourceError {
                XCTAssertEqual(error, .httpStatus(status))
            }
        }
    }

    func testEventSourceFailsWhenBoundedBufferDropsAnEvent() async throws {
        let frame = "data: {\"id\":\"1\",\"type\":\"x\",\"created\":1,\"data\":{}}\n\n"
        EventSourceURLProtocol.streamHandler = { source in
            source.receiveResponse(status: 200, headers: ["Content-Type": "text/event-stream"])
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.1)
                source.load(Data((frame + frame + frame).utf8))
                source.finish()
            }
        }
        let source = URLSessionEventSource(bufferCapacity: 1, urlProtocolClasses: [EventSourceURLProtocol.self])
        let stream = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
        try await Task.sleep(nanoseconds: 250_000_000)
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        XCTAssertNotNil(firstEvent)
        do {
            _ = try await iterator.next()
            XCTFail("expected bounded-buffer failure")
        } catch let error as EventSourceError {
            XCTAssertEqual(error, .bufferOverflow)
        }
    }

    func testEventSourceCancellationStopsURLProtocolLoading() async throws {
        let stopped = expectation(description: "URLProtocol stopLoading called")
        EventSourceURLProtocol.streamHandler = { source in
            source.receiveResponse(status: 200, headers: ["Content-Type": "text/event-stream"])
            source.load(Data(": heartbeat\n\n".utf8))
        }
        EventSourceURLProtocol.stopHandler = { stopped.fulfill() }

        let source = URLSessionEventSource(urlProtocolClasses: [EventSourceURLProtocol.self])
        var stream: AsyncThrowingStream<EventEnvelope, Error>? = try await source.open(
            connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event")
        )
        stream = nil
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testExplicitSubscriptionCancellationStopsBeforeConsumption() async throws {
        let stopped = expectation(description: "URLProtocol stopLoading called")
        EventSourceURLProtocol.streamHandler = { source in
            source.receiveResponse(status: 200, headers: ["Content-Type": "text/event-stream"])
        }
        EventSourceURLProtocol.stopHandler = { stopped.fulfill() }

        let source = URLSessionEventSource(urlProtocolClasses: [EventSourceURLProtocol.self])
        let subscription = try await source.openSubscription(
            connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event")
        )
        subscription.cancel()

        await fulfillment(of: [stopped], timeout: 2)
    }

    func testHeartbeatKeepsOpenStreamAlivePastRequestTimeout() async throws {
        let finished = expectation(description: "URLProtocol stream finished")
        EventSourceURLProtocol.finishHandler = { finished.fulfill() }
        let frame = Data("data: {\"id\":\"heartbeat\",\"type\":\"ready\",\"created\":1,\"data\":{}}\n\n".utf8)
        EventSourceURLProtocol.streamHandler = { source in
            source.receiveResponse(status: 200, headers: ["Content-Type": "text/event-stream"])
            DispatchQueue.global().async {
                for _ in 0..<4 {
                    Thread.sleep(forTimeInterval: 0.02)
                    source.load(Data(": heartbeat\n\n".utf8))
                }
                source.load(frame)
                source.finish()
            }
        }
        let source = URLSessionEventSource(timeout: 0.05, urlProtocolClasses: [EventSourceURLProtocol.self])
        let stream = try await source.open(connection: eventConnection(), request: HTTPRequest(method: .get, relativePath: "/api/event"))
        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event?.id, "heartbeat")
        await fulfillment(of: [finished], timeout: 2)
    }

    func testNormalEventRequiresCreated() {
        let json = Data("{\"id\":\"1\",\"type\":\"ready\",\"data\":{}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EventEnvelope.self, from: json))
    }

    func testNormalEventAcceptsFractionalCreated() throws {
        let json = Data("{\"id\":\"1\",\"type\":\"ready\",\"created\":1.25,\"data\":{}}".utf8)
        let event = try JSONDecoder().decode(EventEnvelope.self, from: json)
        XCTAssertEqual(event.created, 1.25)
    }

    func testCreatedRejectsInvalidOrNonFiniteValues() {
        for value in ["\"invalid\"", "1e999"] {
            let json = Data("{\"id\":\"1\",\"type\":\"ready\",\"created\":\(value),\"data\":{}}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(EventEnvelope.self, from: json), "created: \(value)")
        }
    }

    func testServerConnectedMayOmitCreated() throws {
        let json = Data("{\"id\":\"1\",\"type\":\"server.connected\",\"data\":{}}".utf8)
        let event = try JSONDecoder().decode(EventEnvelope.self, from: json)
        XCTAssertNil(event.created)
    }

    func testStreamResourceTimeoutIsNotShortDefault() {
        XCTAssertGreaterThan(URLSessionEventSource.streamResourceTimeout, 7 * 24 * 60 * 60)
    }
}

private struct EventCredentials: CredentialCapability {
    var safeDescription: String { "event-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        ServiceCredential(username: "user", password: "pass")
    }
}

private func eventConnection() -> ServiceConnection {
    ServiceConnection(
        connectionID: ConnectionID(rawValue: "event-test"),
        endpoint: ServiceEndpoint(baseURL: URL(string: "http://127.0.0.1")!),
        credentialCapability: EventCredentials()
    )
}

private final class EventSourceURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, [String: String])?)?
    nonisolated(unsafe) static var statusHandler: ((URLRequest) -> (Int, Data, [String: String])?)?
    nonisolated(unsafe) static var streamHandler: ((EventSourceURLProtocol) -> Void)?
    nonisolated(unsafe) static var stopHandler: (() -> Void)?
    nonisolated(unsafe) static var finishHandler: (() -> Void)?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let streamHandler = Self.streamHandler {
            streamHandler(self)
            return
        }
        guard let result = Self.handler?(request) ?? Self.statusHandler?(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: result.2)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    func receiveResponse(status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func load(_ data: Data) {
        guard !stopped else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard !stopped else { return }
        client?.urlProtocolDidFinishLoading(self)
        Self.finishHandler?()
    }

    override func stopLoading() {
        stopped = true
        Self.stopHandler?()
    }
}
