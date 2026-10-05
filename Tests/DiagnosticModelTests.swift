import XCTest
@testable import Joycode

@MainActor
final class DiagnosticModelTests: XCTestCase {
    func testConnectPublishesSafeContextWithoutOpeningEvents() async throws {
        let connection = syntheticConnection(version: "2.0.20")
        let model = DiagnosticModel(discover: { connection })

        model.connect()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.status, .connected(version: "2.0.20"))
        XCTAssertEqual(model.currentContext?.version, "2.0.20")
        XCTAssertEqual(model.currentContext?.generation, 1)
        model.disconnect()
        XCTAssertEqual(model.status, .disconnected)
        XCTAssertNil(model.currentContext)
    }

    func testUnauthorizedAndMismatchAreDistinctFromGenericFailure() async throws {
        let unauthorized = DiagnosticModel(discover: { throw ServiceDiscoveryError.unauthorized })
        unauthorized.connect()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(unauthorized.status, .unauthorized)

        let mismatch = DiagnosticModel(discover: { throw ServiceDiscoveryError.versionMismatch })
        mismatch.connect()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(mismatch.status, .incompatible)

        let failed = DiagnosticModel(discover: { throw ServiceDiscoveryError.requestFailed })
        failed.connect()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(failed.status, .failure)
    }

    func testTimeoutBecomesVisibleFailure() async throws {
        let model = DiagnosticModel(
            discover: { try await Task.sleep(for: .seconds(10)); throw CancellationError() },
            timeout: .milliseconds(10)
        )
        model.connect()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.status, .failure)
    }

    func testCanceledGenerationCannotPublishStaleContext() async throws {
        let gate = Gate()
        let first = XCTestExpectation(description: "first started")
        let calls = CallBox()
        let model = DiagnosticModel(discover: {
            calls.value += 1
            if calls.value == 1 { first.fulfill(); await gate.wait() }
            return syntheticConnection(version: calls.value == 1 ? "stale" : "current")
        })

        model.connect()
        await fulfillment(of: [first], timeout: 1)
        model.disconnect()
        model.connect()
        await gate.release()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.status, .connected(version: "current"))
        XCTAssertEqual(model.currentContext?.generation, 3)
        model.disconnect()
    }
}

private struct NoCredentials: CredentialCapability {
    var safeDescription: String { "none" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private func syntheticConnection(version: String) -> LocalServiceConnection {
    let registration = ServiceRegistration(url: "http://127.0.0.1", pid: 1, id: nil, version: version, password: nil)
    let info = ServerInfo(version: version, pid: 1, urls: [], paths: .init(tmp: "synthetic"))
    let service = ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://127.0.0.1")!), credentialCapability: NoCredentials())
    return LocalServiceConnection(connection: service, registration: registration, info: info)
}

private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

private final class CallBox: @unchecked Sendable {
    var value = 0
}
