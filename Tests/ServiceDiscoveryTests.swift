import Foundation
import XCTest
@testable import Joycode

private struct DiscoveryTransport: HTTPTransport {
    let body: Data
    let status: Int
    let recorder: Recorder

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        let credential = try await connection.credentialCapability.credential(for: connection.connectionID)
        await recorder.record(request: request, credential: credential)
        return HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}

private func makeRegistrationFile(pid: Int = 12, version: String? = nil) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("service.json")
    var fields: [String: Any] = [
        "url": "http://127.0.0.1:4096",
        "pid": pid
    ]
    if let version { fields["version"] = version }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return (directory, file)
}

private func serverInfo(version: String = "v", pid: Int = 12) -> Data {
    let versionField = "\"version\":\"\(version)\""
    let pidField = "\"pid\":\(pid)"
    let urlsField = "\"urls\":[\"http://127.0.0.1:4096\"]"
    let pathsField = "\"paths\":{\"tmp\":\"/private/tmp\"}"
    return Data("{\(versionField),\(pidField),\(urlsField),\(pathsField)}".utf8)
}

private actor Recorder {
    var request: HTTPRequest?
    var credential: ServiceCredential?
    func record(request: HTTPRequest, credential: ServiceCredential?) {
        self.request = request
        self.credential = credential
    }
}

final class ServiceDiscoveryTests: XCTestCase {
    func testServiceDescriptionsAndMirrorsDoNotExposeServerDetails() {
        let urlSentinel = "http://synthetic.invalid:1234"
        let pathSentinel = "/synthetic/private/tmp"
        let registrationIDSentinel = "synthetic-registration-id"
        let passwordSentinel = "synthetic-password"
        let capabilitySentinel = "synthetic-credential-capability"
        let info = ServerInfo(
            version: "synthetic-version",
            pid: 123,
            urls: [urlSentinel],
            paths: ServerInfo.Paths(tmp: pathSentinel)
        )
        let registration = ServiceRegistration(
            url: urlSentinel,
            pid: 123,
            id: registrationIDSentinel,
            version: "synthetic-version",
            password: passwordSentinel
        )
        let connection = ServiceConnection(
            connectionID: ConnectionID(rawValue: capabilitySentinel),
            endpoint: ServiceEndpoint(baseURL: URL(string: urlSentinel)!),
            credentialCapability: RegistrationCredentialCapability(
                registration: registration,
                connectionID: ConnectionID(rawValue: capabilitySentinel)
            )
        )
        let local = LocalServiceConnection(connection: connection, registration: registration, info: info)

        for value in [info, info.paths, local] {
            let described = String(describing: value)
            let reflected = String(reflecting: value)
            XCTAssertTrue(Mirror(reflecting: value).children.isEmpty)
            for sentinel in [urlSentinel, pathSentinel, registrationIDSentinel, passwordSentinel, capabilitySentinel] {
                XCTAssertFalse(described.contains(sentinel))
                XCTAssertFalse(reflected.contains(sentinel))
            }
        }
    }

    func testDiscoveryUsesExactInfoRequestAndRegisteredCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service.json")
        try Data(#"{"url":"http://127.0.0.1:4096","pid":12,"password":"secret","version":"v"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recorder = Recorder()
        let transport = DiscoveryTransport(body: Data(#"{"version":"v","pid":12,"urls":["http://127.0.0.1:4096"],"paths":{"tmp":"/private/tmp"}}"#.utf8), status: 200, recorder: recorder)
        let result = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover(version: .any)
        XCTAssertEqual(result.info.pid, 12)
        let request = await recorder.request
        XCTAssertEqual(request?.method.rawValue, "GET")
        XCTAssertEqual(request?.relativePath, "/api/info")
        XCTAssertEqual(request?.queryItems, [])
        let credential = await recorder.credential
        XCTAssertEqual(credential?.username, "opencode")
        XCTAssertEqual(credential?.password, "secret")
    }

    func testMissingPasswordProbesLoopbackWithoutCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service.json")
        try Data(#"{"url":"http://127.0.0.1:4096","pid":12}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recorder = Recorder()
        let transport = DiscoveryTransport(body: Data(#"{"version":"v","pid":12,"urls":["http://127.0.0.1:4096"],"paths":{"tmp":"/private/tmp"}}"#.utf8), status: 200, recorder: recorder)

        _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover()

        let request = await recorder.request
        XCTAssertEqual(request?.method.rawValue, "GET")
        XCTAssertEqual(request?.relativePath, "/api/info")
        XCTAssertEqual(request?.queryItems, [])
        let credential = await recorder.credential
        XCTAssertNil(credential)
    }

    func testRemoteRegistrationIsRejectedBeforeTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service.json")
        try Data(#"{"url":"http://example.com:4096","pid":12}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recorder = Recorder()
        let transport = DiscoveryTransport(body: Data(), status: 200, recorder: recorder)
        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover()
            XCTFail("expected unsafe endpoint")
        } catch let error as ServiceDiscoveryError {
            XCTAssertEqual(error, .unsafeEndpoint)
        }
        let request = await recorder.request
        XCTAssertNil(request)
    }

    func testInvalidRegistrationIsRejectedBeforeProbe() async throws {
        let (directory, file) = try makeRegistrationFile(pid: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let transport = DiscoveryTransport(body: serverInfo(), status: 200, recorder: recorder)

        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover()
            XCTFail("expected malformed registration")
        } catch let error as ServiceDiscoveryError {
            XCTAssertEqual(error, .registrationMalformed)
        }
        let request = await recorder.request
        XCTAssertNil(request)
    }

    func testResponsePIDMismatchIsRejected() async throws {
        let (directory, file) = try makeRegistrationFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DiscoveryTransport(body: serverInfo(pid: 13), status: 200, recorder: Recorder())
        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover()
            XCTFail("expected process mismatch")
        } catch let error as ServiceDiscoveryError { XCTAssertEqual(error, .processMismatch) }
    }

    func testZeroResponsePIDDecodesButMismatchesPositiveRegistration() async throws {
        let (directory, file) = try makeRegistrationFile(pid: 12)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = serverInfo(pid: 0)
        XCTAssertEqual(try ServerInfo.decode(body).pid, 0)
        let transport = DiscoveryTransport(body: body, status: 200, recorder: Recorder())

        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover()
            XCTFail("expected process mismatch")
        } catch let error as ServiceDiscoveryError {
            XCTAssertEqual(error, .processMismatch)
        }
    }

    func testRegistrationVersionMustMatchResponseEvenForAnyRequirement() async throws {
        let (directory, file) = try makeRegistrationFile(version: "registered")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DiscoveryTransport(body: serverInfo(version: "served"), status: 200, recorder: Recorder())
        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: transport).discover(version: .any)
            XCTFail("expected version mismatch")
        } catch let error as ServiceDiscoveryError { XCTAssertEqual(error, .versionMismatch) }
    }

    func testAnyAllowsUnpinnedRegistrationVersion() async throws {
        let (directory, file) = try makeRegistrationFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: DiscoveryTransport(body: serverInfo(version: "served"), status: 200, recorder: Recorder())).discover(version: .any)
        XCTAssertEqual(result.info.version, "served")
    }

    func testExactVersionMismatchAndMatch() async throws {
        let (directory, file) = try makeRegistrationFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let discovery = LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: DiscoveryTransport(body: serverInfo(version: "served"), status: 200, recorder: Recorder()))
        do {
            _ = try await discovery.discover(version: .exact("other"))
            XCTFail("expected version mismatch")
        } catch let error as ServiceDiscoveryError { XCTAssertEqual(error, .versionMismatch) }
        let result = try await discovery.discover(version: .exact("served"))
        XCTAssertEqual(result.info.version, "served")
    }

    func testMalformedServerInfoAndHTTPStatuses() async throws {
        let (directory, file) = try makeRegistrationFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (status, expected) in [(401, ServiceDiscoveryError.unauthorized), (503, ServiceDiscoveryError.unexpectedStatus)] {
            do {
                _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: DiscoveryTransport(body: serverInfo(), status: status, recorder: Recorder())).discover()
                XCTFail("expected status error")
            } catch let error as ServiceDiscoveryError { XCTAssertEqual(error, expected) }
        }
        do {
            _ = try await LocalServiceDiscovery(registrationReader: LocalServiceRegistrationReader(fileURL: file), transport: DiscoveryTransport(body: Data(#"{"version":"v"}"#.utf8), status: 200, recorder: Recorder())).discover()
            XCTFail("expected malformed server info")
        } catch let error as ServiceDiscoveryError { XCTAssertEqual(error, .malformedServerInfo) }
    }
}
