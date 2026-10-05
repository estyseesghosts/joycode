import Foundation
import XCTest
@testable import Joycode

final class ServiceRegistrationTests: XCTestCase {
    func testResolvesXDGStateBeforeHomeWithoutReadingEither() {
        XCTAssertEqual(
            ServiceRegistrationPath.resolve(environment: ["XDG_STATE_HOME": "/tmp/state"], homeDirectory: URL(fileURLWithPath: "/tmp/home"))?.path,
            "/tmp/state/opencode/service.json"
        )
        XCTAssertEqual(
            ServiceRegistrationPath.resolve(environment: [:], homeDirectory: URL(fileURLWithPath: "/tmp/home"))?.path,
            "/tmp/home/.local/state/opencode/service.json"
        )
        XCTAssertNil(ServiceRegistrationPath.resolve(environment: [:]))
    }

    func testReaderRequires0600AndDoesNotRepairPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service.json")
        try Data(#"{"url":"http://127.0.0.1:4096","pid":12}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalServiceRegistrationReader(fileURL: file).read()) { error in
            XCTAssertEqual(error as? ServiceDiscoveryError, .registrationPermissions)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testReaderRejectsMissingAndMalformedRegistration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try LocalServiceRegistrationReader(fileURL: directory.appendingPathComponent("missing.json")).read()) { error in
            XCTAssertEqual(error as? ServiceDiscoveryError, .registrationMissing)
        }

        let file = directory.appendingPathComponent("malformed.json")
        try Data(#"{"url":"http://127.0.0.1:4096"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalServiceRegistrationReader(fileURL: file).read()) { error in
            XCTAssertEqual(error as? ServiceDiscoveryError, .registrationMalformed)
        }
    }

    func testReaderRejectsNonpositiveRegistrationPID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("service.json")
        try Data(#"{"url":"http://127.0.0.1:4096","pid":0}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        XCTAssertThrowsError(try LocalServiceRegistrationReader(fileURL: file).read()) { error in
            XCTAssertEqual(error as? ServiceDiscoveryError, .registrationMalformed)
        }
    }

    func testDescriptionsDoNotExposeRegistrationSecrets() throws {
        let registration = ServiceRegistration(url: "http://127.0.0.1:4096", pid: 12, id: "private-id", version: "private-version", password: "secret")
        XCTAssertFalse(String(describing: registration).contains("secret"))
        XCTAssertFalse(String(describing: registration).contains("private-id"))
    }

    func testDebugAndReflectionDoNotExposeRegistrationSecrets() throws {
        let registration = ServiceRegistration(url: "http://127.0.0.1:4096", pid: 12, id: "private-id", version: "private-version", password: "secret")
        let mirror = Mirror(reflecting: registration)

        XCTAssertTrue(mirror.children.isEmpty)
        XCTAssertFalse(String(reflecting: registration).contains("secret"))
        XCTAssertFalse(String(reflecting: registration).contains("private-id"))
        XCTAssertFalse(String(reflecting: registration).contains("127.0.0.1"))
        XCTAssertFalse(String(reflecting: registration).contains("private-version"))
    }

    func testCredentialCapabilityDebugAndReflectionDoNotExposeDetails() throws {
        let registration = ServiceRegistration(url: "http://127.0.0.1:4096", pid: 12, id: "private-id", version: "private-version", password: "secret")
        let capability = RegistrationCredentialCapability(registration: registration, connectionID: ConnectionID(rawValue: "private-connection"))
        let mirror = Mirror(reflecting: capability)

        XCTAssertTrue(mirror.children.isEmpty)
        XCTAssertFalse(String(describing: capability).contains("secret"))
        XCTAssertFalse(String(reflecting: capability).contains("secret"))
        XCTAssertFalse(String(reflecting: capability).contains("private-connection"))
    }
}
