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
        defer { model.disconnect() }
        let connected = expectation(description: "pinned sandbox server.connected observed")
        var statusObservation: AnyCancellable?
        statusObservation = model.$status.sink { status in
            guard case let .connected(version) = status,
                  version == Self.expectedVersion
            else { return }
            connected.fulfill()
        }
        model.connect()
        await fulfillment(of: [connected], timeout: 10)
        statusObservation?.cancel()
        model.disconnect()
        XCTAssertEqual(model.status, .disconnected)
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
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        else { return false }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.dropFirst().allSatisfy {
            guard let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }
}
