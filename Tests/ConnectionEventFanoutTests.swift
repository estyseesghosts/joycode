import Foundation
import XCTest
@testable import Joycode

// MARK: - Connection event fanout tests (R08)
//
// Fanout delivery rules, plus the owner's single-subscription -> fanout path
// over a fake event source. No network is touched.

@MainActor
final class ConnectionEventFanoutTests: XCTestCase {
    private func envelope(_ type: String, data: String = "{}") throws -> EventEnvelope {
        let json = "{\"id\":\"evt-\(type)\",\"type\":\"\(type)\",\"created\":1,\"data\":\(data)}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    private func label(_ signal: ConnectionEventSignal) -> String {
        switch signal {
        case .connected(let generation): return "connected:\(generation)"
        case .event(let generation, let envelope): return "event:\(generation):\(envelope.type)"
        case .failed(let generation): return "failed:\(generation)"
        }
    }

    // MARK: Fanout alone

    func testSignalsForCurrentGenerationReachAllObserversInOrder() throws {
        let fanout = ConnectionEventFanout()
        var first: [String] = []
        var second: [String] = []
        let a = fanout.addObserver { first.append(self.label($0)) }
        let b = fanout.addObserver { second.append(self.label($0)) }
        fanout.reset(generation: 1)
        fanout.deliver(.connected(generation: 1))
        fanout.deliver(.event(generation: 1, envelope: try envelope("session.tool.success")))
        XCTAssertEqual(first, ["connected:1", "event:1:session.tool.success"])
        XCTAssertEqual(second, first)
        withExtendedLifetime((a, b)) {}
    }

    func testSignalsBeforeResetOrForOtherGenerationAreDropped() throws {
        let fanout = ConnectionEventFanout()
        var seen: [String] = []
        let observation = fanout.addObserver { seen.append(self.label($0)) }
        fanout.deliver(.connected(generation: 1))
        XCTAssertTrue(seen.isEmpty)
        fanout.reset(generation: 2)
        fanout.deliver(.event(generation: 1, envelope: try envelope("session.tool.success")))
        fanout.deliver(.failed(generation: 1))
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(fanout.phase, .connecting(generation: 2))
        withExtendedLifetime(observation) {}
    }

    func testLateObserverReceivesReadyOrFailedPhase() {
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        var beforeReady: [String] = []
        let early = fanout.addObserver { beforeReady.append(self.label($0)) }
        XCTAssertTrue(beforeReady.isEmpty)

        fanout.deliver(.connected(generation: 1))
        var afterReady: [String] = []
        let late = fanout.addObserver { afterReady.append(self.label($0)) }
        XCTAssertEqual(afterReady, ["connected:1"])

        fanout.deliver(.failed(generation: 1))
        var afterFailure: [String] = []
        let later = fanout.addObserver { afterFailure.append(self.label($0)) }
        XCTAssertEqual(afterFailure, ["failed:1"])
        withExtendedLifetime((early, late, later)) {}
    }

    func testResetClearsReplayedPhase() {
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        fanout.deliver(.connected(generation: 1))
        fanout.reset(generation: 2)
        var seen: [String] = []
        let observation = fanout.addObserver { seen.append(self.label($0)) }
        XCTAssertTrue(seen.isEmpty)
        fanout.reset(generation: nil)
        XCTAssertEqual(fanout.phase, .idle)
        withExtendedLifetime(observation) {}
    }

    func testCancelledOrReleasedObserverStopsReceiving() async {
        let fanout = ConnectionEventFanout()
        fanout.reset(generation: 1)
        var seen: [String] = []
        let observation = fanout.addObserver { seen.append(self.label($0)) }
        XCTAssertEqual(fanout.observerCount, 1)
        observation.cancel()
        for _ in 0..<20 where fanout.observerCount != 0 { await Task.yield() }
        XCTAssertEqual(fanout.observerCount, 0)
        fanout.deliver(.connected(generation: 1))
        XCTAssertTrue(seen.isEmpty)

        var releasedSeen: [String] = []
        var released: ConnectionEventObservation? = fanout.addObserver { releasedSeen.append(self.label($0)) }
        XCTAssertNotNil(released)
        released = nil
        for _ in 0..<20 where fanout.observerCount != 0 { await Task.yield() }
        XCTAssertEqual(fanout.observerCount, 0)
    }

    // MARK: Owner -> fanout

    func testOwnerFansOutOneSubscriptionAndMapsReadyEventsAndFailure() async throws {
        let source = FanoutTestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { fanoutLocalService() })
        let owner = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)
        var first: [String] = []
        var second: [String] = []
        let a = owner.fanout.addObserver { first.append(self.label($0)) }
        let b = owner.fanout.addObserver { second.append(self.label($0)) }

        connectionOwner.connect()
        let stream = try await source.waitForOpen()
        let generation = try XCTUnwrap(connectionOwner.currentContext?.generation)
        stream.yield(try envelope("server.connected"))
        stream.yield(try envelope("session.inbox.delivered", data: "{\"sessionID\":\"ses-1\"}"))
        await eventually { first.count == 2 }
        XCTAssertEqual(first, ["connected:\(generation)", "event:\(generation):session.inbox.delivered"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(source.openCount, 1)

        stream.finish(throwing: FanoutTestError.failed)
        await eventually { first.count == 3 }
        XCTAssertEqual(first.last, "failed:\(generation)")
        XCTAssertTrue(owner.subscriptionFailed)
        XCTAssertEqual(owner.fanout.phase, .failed(generation: generation))
        withExtendedLifetime((a, b)) {}
    }

    func testOwnerReplacementIgnoresOldStreamSignals() async throws {
        let source = FanoutTestEventSource()
        let connectionOwner = ServiceConnectionOwner(discover: { fanoutLocalService() })
        let owner = ConnectionEventOwner(connectionOwner: connectionOwner, source: source)
        var seen: [String] = []
        let observation = owner.fanout.addObserver { seen.append(self.label($0)) }

        connectionOwner.connect()
        let first = try await source.waitForOpen()
        connectionOwner.connect()
        let second = try await source.waitForOpen(after: 1)
        let generation = try XCTUnwrap(connectionOwner.currentContext?.generation)

        first.yield(try envelope("server.connected"))
        first.yield(try envelope("session.tool.success", data: "{\"sessionID\":\"ses-1\"}"))
        first.finish(throwing: FanoutTestError.failed)
        second.yield(try envelope("server.connected"))
        await eventually { seen.contains("connected:\(generation)") }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(seen, ["connected:\(generation)"])
        XCTAssertEqual(owner.fanout.phase, .ready(generation: generation))
        withExtendedLifetime(observation) {}
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not become true")
    }
}

private enum FanoutTestError: Error { case failed }

private final class FanoutTestEventSource: ConnectionEventSubscriptionSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<EventEnvelope, Error>.Continuation] = []

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func openConnectionEventSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> ConnectionEventSubscription {
        let stream = AsyncThrowingStream<EventEnvelope, Error> { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
        return ConnectionEventSubscription(stream: stream)
    }

    func waitForOpen(after index: Int = 0) async throws -> AsyncThrowingStream<EventEnvelope, Error>.Continuation {
        for _ in 0..<200 {
            if let continuation = continuation(at: index) { return continuation }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FanoutTestError.failed
    }

    private func continuation(at index: Int) -> AsyncThrowingStream<EventEnvelope, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations.indices.contains(index) ? continuations[index] : nil
    }
}

private struct FanoutTestCredentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private func fanoutLocalService() -> LocalServiceConnection {
    let connection = ServiceConnection(
        connectionID: ConnectionID(rawValue: "test"),
        endpoint: ServiceEndpoint(baseURL: URL(string: "http://127.0.0.1")!),
        credentialCapability: FanoutTestCredentials()
    )
    return LocalServiceConnection(
        connection: connection,
        registration: ServiceRegistration(url: "http://127.0.0.1", pid: 1, id: nil, version: "2.0.20", password: nil),
        info: ServerInfo(version: "2.0.20", pid: 1, urls: [], paths: .init(tmp: "/tmp"))
    )
}
