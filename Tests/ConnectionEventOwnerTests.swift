import Foundation
import XCTest
@testable import Joycode

@MainActor
final class ConnectionEventOwnerTests: XCTestCase {
    func testOneSubscriptionPerGenerationProjectsSafeEventsAndCompletion() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        await eventually { connectionOwner.currentContext != nil }
        let first = try await source.waitForOpen()
        first.yield(try envelope(type: "ready/secret", id: "private-id"))
        await eventually { events.eventCount == 1 }
        XCTAssertNil(events.latestEventType)
        first.finish()
        await eventually { events.subscriptionFailed }
        XCTAssertEqual(events.eventCount, 1)
    }

    func testReplacementCancelsOldAndIgnoresLateEventsAndFailures() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let first = try await source.waitForOpen()
        connectionOwner.connect()
        let second = try await source.waitForOpen(after: 1)
        XCTAssertEqual(source.openCount, 2)

        first.yield(try envelope(type: "old", id: "old-id"))
        first.finish(throwing: TestError.failed)
        second.yield(try envelope(type: "new", id: "new-id"))
        await eventually { source.cancelCount == 1 }
        await eventually { events.eventCount == 1 }
        XCTAssertEqual(events.latestEventType, "new")

        connectionOwner.disconnect()
        second.yield(try envelope(type: "late", id: "late-id"))
        second.finish(throwing: TestError.failed)
        await eventually { source.cancelCount == 2 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(events.eventCount, 0)
        XCTAssertFalse(events.subscriptionFailed)
    }

    func testRemountingRootViewWithAppOwnedEventOwnerDoesNotOpenAnotherStream() async throws {
        let source = TestEventSource()
        let model = DiagnosticModel(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: model, source: source)

        model.connect()
        let stream = try await source.waitForOpen()
        _ = RootView(model: model, eventOwner: events)
        _ = RootView(model: model, eventOwner: events)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source.openCount, 1)

        model.disconnect()
        stream.finish()
        await eventually { source.cancelCount == 1 }
    }

    func testTerminalEventStreamFailureDoesNotChangeConnectedStatus() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let stream = try await source.waitForOpen()
        XCTAssertEqual(connectionOwner.status, .connected(version: "2.0.20"))
        stream.finish(throwing: TestError.failed)

        await eventually { events.subscriptionFailed }
        XCTAssertEqual(connectionOwner.status, .connected(version: "2.0.20"))
        XCTAssertEqual(events.eventCount, 0)
    }

    func testCurrentCancellationErrorIsReportedAsSubscriptionFailure() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let stream = try await source.waitForOpen()
        stream.finish(throwing: CancellationError())

        await eventually { events.subscriptionFailed }
        XCTAssertEqual(source.cancelCount, 1)
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true")
    }
}

private enum TestError: Error { case unused, failed }

private final class TestEventSource: ConnectionEventSubscriptionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<EventEnvelope, Error>.Continuation] = []
    private var openCountStorage = 0
    private var cancelCountStorage = 0

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openCountStorage
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountStorage
    }

    func openConnectionEventSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> ConnectionEventSubscription {
        let stream = AsyncThrowingStream<EventEnvelope, Error> { continuation in
            lock.lock()
            continuations.append(continuation)
            openCountStorage += 1
            lock.unlock()
        }
        return ConnectionEventSubscription(stream: stream) { [weak self] in
            guard let self else { return }
            lock.lock()
            cancelCountStorage += 1
            lock.unlock()
        }
    }

    func waitForOpen(after index: Int = 0) async throws -> AsyncThrowingStream<EventEnvelope, Error>.Continuation {
        for _ in 0..<100 {
            let continuation = continuation(at: index)
            if let continuation { return continuation }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestError.failed
    }

    private func continuation(at index: Int) -> AsyncThrowingStream<EventEnvelope, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        guard continuations.indices.contains(index) else { return nil }
        return continuations[index]
    }

}

private func envelope(type: String, id: String) throws -> EventEnvelope {
    try JSONDecoder().decode(EventEnvelope.self, from: Data("{\"id\":\"\(id)\",\"type\":\"\(type)\",\"created\":1,\"data\":{}}".utf8))
}

private func testConnection() -> ServiceConnection {
    ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://127.0.0.1")!), credentialCapability: TestCredentials())
}

private func localService() -> LocalServiceConnection {
    LocalServiceConnection(
        connection: testConnection(),
        registration: ServiceRegistration(url: "http://127.0.0.1", pid: 1, id: nil, version: "2.0.20", password: nil),
        info: ServerInfo(version: "2.0.20", pid: 1, urls: [], paths: .init(tmp: "/tmp"))
    )
}

private struct TestCredentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}
