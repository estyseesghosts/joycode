import Foundation
import Combine
import XCTest
@testable import Joycode

@MainActor
final class LiveOptInTests: XCTestCase {
    private static let expectedVersion = "2.0.20"

    func testProductionDiagnosticConnectsToApprovedPinnedSandbox() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JOYCODE_ENABLE_LIVE_TESTS"] == "1",
            "Live tests are disabled. Set JOYCODE_ENABLE_LIVE_TESTS=1 with an approved disposable context."
        )

        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["JOYCODE_LIVE_ENDPOINT"],
              let endpointURL = URL(string: endpoint),
              Self.isLoopback(endpointURL),
              let context = ProcessInfo.processInfo.environment["JOYCODE_LIVE_CONTEXT"],
              context == "approved-disposable"
        else {
            throw XCTSkip("Live tests require a loopback JOYCODE_LIVE_ENDPOINT and JOYCODE_LIVE_CONTEXT=approved-disposable.")
        }

        guard let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty else {
            throw XCTSkip("Live tests require a separately configured XDG_STATE_HOME sandbox.")
        }
        guard let sandboxRootText = environment["JOYCODE_LIVE_SANDBOX_ROOT"],
              !sandboxRootText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Live tests require an explicit JOYCODE_LIVE_SANDBOX_ROOT.")
        }

        let sandboxRoot = URL(fileURLWithPath: sandboxRootText, isDirectory: true).standardizedFileURL
        let expectedStateHome = sandboxRoot.appendingPathComponent("state", isDirectory: true)
            .standardizedFileURL
        guard sandboxRootText.hasPrefix("/"),
              URL(fileURLWithPath: stateHome, isDirectory: true).standardizedFileURL == expectedStateHome,
              Self.isPrivateDirectory(sandboxRoot),
              Self.isPrivateDirectory(expectedStateHome)
        else {
            throw XCTSkip("Live tests require a private sandbox root and XDG_STATE_HOME=<root>/state.")
        }

        let registrationPath = expectedStateHome
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("service.json", isDirectory: false)
        guard Self.isPrivateDirectory(registrationPath.deletingLastPathComponent()),
              Self.isPrivateRegistration(registrationPath)
        else {
            throw XCTSkip("Live tests require a private sandbox registration under the sandbox root.")
        }

        let registration: ServiceRegistration
        do {
            registration = try LocalServiceRegistrationReader(fileURL: registrationPath).read()
        } catch {
            throw XCTSkip("Live tests require a readable sandbox service registration.")
        }

        // Check the passive registration before connecting. This prevents an accidental
        // connection to the known off-pin service and never renders its credential.
        guard registration.version == Self.expectedVersion else {
            throw XCTSkip("Live tests require a registration pinned to OpenCode 2.0.20.")
        }
        guard registration.url == endpoint else {
            throw XCTSkip("Live endpoint must match the separately configured sandbox registration.")
        }

        let model = DiagnosticComposition.productionModel(version: .exact(Self.expectedVersion))
        let eventOwner = ConnectionEventOwner(connectionOwner: model)
        let expectsStreamFailure = environment["JOYCODE_LIVE_EXPECT_STREAM_FAILURE"] == "1"
        let readinessSentinel = sandboxRoot.appendingPathComponent("joycode-r02-ready", isDirectory: false)
        var readinessSentinelCreated = false
        let firstConnected = expectation(description: "pinned sandbox first connection observed")
        let reconnected = expectsStreamFailure
            ? expectation(description: "pinned sandbox reconnection observed")
            : nil
        let firstEventObserved = expectation(description: "pinned sandbox first server.connected event observed")
        let secondEventObserved = expectsStreamFailure
            ? expectation(description: "pinned sandbox second server.connected event observed")
            : nil
        var statusObservation: AnyCancellable?
        var eventObservation: AnyCancellable?
        var firstConnectionObserved = false
        var reconnectedObserved = false
        var firstEventMarkerObserved = false
        var secondEventMarkerObserved = false
        var awaitingReconnect = false
        defer {
            statusObservation?.cancel()
            eventObservation?.cancel()
            model.disconnect()
            if readinessSentinelCreated {
                try? FileManager.default.removeItem(at: readinessSentinel)
            }
        }
        statusObservation = model.$status.sink { status in
            guard case let .connected(version) = status,
                  version == Self.expectedVersion
            else { return }
            if !firstConnectionObserved {
                firstConnectionObserved = true
                firstConnected.fulfill()
            } else if awaitingReconnect {
                reconnectedObserved = true
                reconnected?.fulfill()
            }
        }
        eventObservation = eventOwner.$latestEventType.sink { eventType in
            guard eventType == "server.connected" else { return }
            if awaitingReconnect {
                secondEventMarkerObserved = true
                secondEventObserved?.fulfill()
            } else if !firstEventMarkerObserved {
                firstEventMarkerObserved = true
                firstEventObserved.fulfill()
            }
        }
        model.connect()
        await fulfillment(of: [firstConnected, firstEventObserved], timeout: 10)
        guard firstConnectionObserved, firstEventMarkerObserved else {
            XCTFail("The pinned sandbox first connection did not produce both the connected status and server.connected event.")
            return
        }
        guard expectsStreamFailure else {
            model.disconnect()
            XCTAssertEqual(model.status, .disconnected)
            return
        }

        model.disconnect()
        let ownerCleared = await waitUntil(timeout: 5) {
            model.status == .disconnected &&
                eventOwner.eventCount == 0 &&
                eventOwner.latestEventType == nil &&
                !eventOwner.subscriptionFailed
        }
        XCTAssertTrue(ownerCleared, "Connection event owner did not clear after disconnect.")

        reconnectedObserved = false
        secondEventMarkerObserved = false
        awaitingReconnect = true
        model.connect()
        if let secondEventObserved, let reconnected {
            await fulfillment(of: [secondEventObserved, reconnected], timeout: 10)
        }
        guard reconnectedObserved, secondEventMarkerObserved else {
            XCTFail("The pinned sandbox reconnect did not produce both the reconnect status and second server.connected event.")
            return
        }

        guard !FileManager.default.fileExists(atPath: readinessSentinel.path) else {
            throw XCTSkip("The stream-failure readiness sentinel already exists in the sandbox.")
        }
        do {
            try Data().write(to: readinessSentinel, options: [.atomic])
            readinessSentinelCreated = true
        } catch {
            XCTFail("Could not create stream-failure readiness sentinel: \(error)")
            return
        }

        let streamFailed = await waitUntil(timeout: 10) { eventOwner.subscriptionFailed }
        XCTAssertTrue(streamFailed, "The event stream did not report failure after the readiness sentinel was created.")
        XCTAssertEqual(model.status, .connected(version: Self.expectedVersion))
        model.disconnect()
    }

    private func waitUntil(
        timeout: Int,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<(timeout * 20) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else { return false }
        return true
    }

    private static func isPrivateRegistration(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        else { return false }
        return URL(fileURLWithPath: url.path).standardizedFileURL == url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased()
        else { return false }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalizedHost == "::1" { return true }
        let octets = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.dropFirst().allSatisfy {
            guard let value = Int($0), String(value) == $0 else { return false }
            return (0...255).contains(value)
        }
    }

    func testLoopbackEndpointAcceptsCanonicalLoopbackIPLiteralForms() {
        let accepted = [
            "http://127.0.0.1:4096",
            "https://127.255.255.255",
            "http://[::1]:4096"
        ]

        for endpoint in accepted {
            XCTAssertTrue(Self.isLoopback(URL(string: endpoint)!), endpoint)
        }
    }

    func testLoopbackEndpointRejectsNonCanonicalOrUnsafeForms() {
        let rejected = [
            "http://localhost",
            "http://127.0.0.1.",
            "http://127..0.1",
            "http://127.00.0.1",
            "http://127.0.0.01",
            "http://127.0.0.1.example",
            "http://128.0.0.1",
            "http://[::2]",
            "http://user:password@127.0.0.1",
            "ftp://127.0.0.1",
            "http://127.0.0.1?query",
            "http://127.0.0.1#fragment"
        ]

        for endpoint in rejected {
            XCTAssertFalse(Self.isLoopback(URL(string: endpoint)!), endpoint)
        }
    }
}
