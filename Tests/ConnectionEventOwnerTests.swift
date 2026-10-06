import Foundation
import Combine
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
        let transport: any HTTPTransport = URLSessionHTTPTransport()
        _ = RootView(model: model, eventOwner: events, transport: transport)
        _ = RootView(model: model, eventOwner: events, transport: transport)
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

    func testStormDeliversAllInOrderWithCoalescedDiagnostics() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let stream = try await source.waitForOpen()
        var receivedIDs: [String] = []
        let observation = events.fanout.addObserver { signal in
            if case .event(_, let envelope) = signal { receivedIDs.append(envelope.id) }
        }
        var diagnosticEmissions = 0
        let cancellable = events.$diagnostics.sink { _ in diagnosticEmissions += 1 }

        let total = 10_000
        for i in 0..<total {
            stream.yield(try envelope(type: "storm.event", id: "\(i)"))
        }

        await eventually { receivedIDs.count == total }
        XCTAssertEqual(receivedIDs, (0..<total).map(String.init))
        await eventually { events.eventCount == total }
        XCTAssertEqual(events.latestEventType, "storm.event")
        // Initial value plus a handful of burst flushes: nowhere near one
        // publication per event.
        XCTAssertLessThan(diagnosticEmissions, 1000)
        withExtendedLifetime((observation, cancellable)) {}
    }

    func testStreamFailurePublishesFailedWithoutWaitingForFlush() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let stream = try await source.waitForOpen()
        var failedSignals = 0
        let observation = events.fanout.addObserver { signal in
            if case .failed = signal { failedSignals += 1 }
        }
        stream.yield(try envelope(type: "burst.event", id: "burst-1"))
        stream.finish(throwing: TestError.failed)

        await eventually { events.subscriptionFailed }
        XCTAssertEqual(failedSignals, 1)
        await eventually { events.eventCount == 1 }
        XCTAssertEqual(events.latestEventType, "burst.event")
        withExtendedLifetime(observation) {}
    }

    func testGenerationChangeCancelsPendingDiagnosticFlush() async throws {
        let source = TestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { localService() })
        let events = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)

        connectionOwner.connect()
        let first = try await source.waitForOpen()
        for i in 0..<5 {
            first.yield(try envelope(type: "old", id: "old-\(i)"))
        }
        connectionOwner.connect()
        _ = try await source.waitForOpen(after: 1)

        // The stale burst flush must never publish the old generation's
        // counts into the new generation; the reset stays at zero.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events.eventCount, 0)
        XCTAssertNil(events.latestEventType)
        XCTAssertFalse(events.subscriptionFailed)

        let second = try await source.waitForOpen(after: 1)
        second.yield(try envelope(type: "new", id: "new-id"))
        await eventually { events.eventCount == 1 }
        XCTAssertEqual(events.latestEventType, "new")
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

private actor DiscoveryGate {
    private(set) var count = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async { count += 1; if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private actor DiscoveryCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}

extension ConnectionEventOwnerTests {
    private func eventuallyAsync(_ predicate: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("condition not reached")
    }

    func testSettledConnectReleasesOperationWithoutChangingReconnectOrDisconnect() async throws {
        let counter = DiscoveryCounter()
        let owner = ServiceConnectionOwner(discover: { await counter.hit(); return localService() })

        owner.connect()
        await eventually { owner.currentContext != nil }
        try await Task.sleep(for: .milliseconds(20))
        let settledCount = await counter.count
        XCTAssertEqual(settledCount, 1)

        owner.connect()
        await eventuallyAsync { let n = await counter.count; return n == 2 && owner.currentContext?.generation == 2 }
        let reconnectCount = await counter.count
        XCTAssertEqual(reconnectCount, 2)

        try await Task.sleep(for: .milliseconds(20))
        owner.disconnect()
        XCTAssertEqual(owner.status, .disconnected)
        XCTAssertNil(owner.currentContext)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(owner.status, .disconnected)
    }

    func testFinishingStaleAttemptCannotReleaseOrOverwriteNewerGeneration() async throws {
        let first = DiscoveryGate()
        let second = DiscoveryGate()
        let counter = DiscoveryCounter()
        let owner = ServiceConnectionOwner(discover: {
            await counter.hit()
            if await counter.count == 1 { await first.enter() } else { await second.enter() }
            return localService()
        })

        owner.connect()
        await eventuallyAsync { await counter.count == 1 }
        owner.connect()
        await eventuallyAsync { await counter.count == 2 }
        await first.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(owner.status, .connecting)
        XCTAssertNil(owner.currentContext)

        await second.open()
        await eventually { owner.currentContext?.generation == 2 }
        XCTAssertEqual(owner.status, .connected(version: "2.0.20"))
        owner.disconnect()
        XCTAssertEqual(owner.status, .disconnected)
    }
}
