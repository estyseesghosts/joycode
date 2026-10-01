import XCTest
@testable import Joycode

private func accepts(_ value: ProjectID) -> String { value.rawValue }
private func accepts(_ value: SessionID) -> String { value.rawValue }
private func accepts(_ value: ConnectionID) -> String { value.rawValue }
private func accepts(_ value: LocationID) -> String { value.rawValue }
private func accepts(_ value: WorkspaceID) -> String { value.rawValue }
private func accepts(_ value: WorktreeID) -> String { value.rawValue }
private func accepts(_ value: ParentSessionID) -> String { value.rawValue }
private func accepts(_ value: TabID) -> String { value.rawValue }

final class F03ContractsTests: XCTestCase {
    func testIdentifiersRemainNominalAndRoundTrip() throws {
        XCTAssertEqual(accepts(ProjectID(rawValue: "p")), "p")
        XCTAssertEqual(accepts(SessionID(rawValue: "s")), "s")
        XCTAssertEqual(accepts(ConnectionID(rawValue: "c")), "c")
        XCTAssertEqual(accepts(LocationID(rawValue: "l")), "l")
        XCTAssertEqual(accepts(WorkspaceID(rawValue: "w")), "w")
        XCTAssertEqual(accepts(WorktreeID(rawValue: "t")), "t")
        XCTAssertEqual(accepts(ParentSessionID(rawValue: "s")), "s")
        XCTAssertEqual(accepts(TabID(rawValue: "tab")), "tab")

        let parent = ParentSessionID(SessionID(rawValue: "session"))
        XCTAssertEqual(parent.sessionID, SessionID(rawValue: "session"))
    }

    func testTransportReceivesExplicitConnectionAndRequestRouting() async throws {
        let connectionID = ConnectionID(rawValue: "configured")
        let endpoint = ServiceEndpoint(baseURL: URL(string: "https://service.example.test:1234/root")!)
        let capability = TestCredentialCapability()
        let connection = ServiceConnection(
            connectionID: connectionID,
            endpoint: endpoint,
            credentialCapability: capability
        )
        let request = HTTPRequest(
            method: .get,
            relativePath: "/api/location",
            queryItems: [HTTPQueryItem(name: "location[directory]", value: "/chosen")]
        )
        let transport = CapturingHTTPTransport()

        _ = try await transport.send(connection: connection, request: request)
        guard let captured = await transport.captured else {
            XCTFail("transport did not capture the request")
            return
        }

        XCTAssertEqual(captured.connection.connectionID, connectionID)
        XCTAssertEqual(captured.connection.endpoint.baseURL, endpoint.baseURL)
        XCTAssertEqual(captured.request.relativePath, "/api/location")
        XCTAssertEqual(captured.request.queryItems, [
            HTTPQueryItem(name: "location[directory]", value: "/chosen")
        ])
    }

    func testCredentialDescriptionsRedactPassword() {
        let passwordSentinel = "credential-password-sentinel-secret"
        let credential = ServiceCredential(username: "alice", password: passwordSentinel)

        let representations = [
            credential.description,
            credential.debugDescription,
            String(describing: credential),
            String(reflecting: credential)
        ]
        for representation in representations {
            XCTAssertFalse(representation.contains(passwordSentinel), representation)
            XCTAssertTrue(representation.contains("<redacted>"), representation)
        }

        let mirror = Mirror(reflecting: credential)
        XCTAssertEqual(mirror.children.map(\.label), ["username", "password"])
        XCTAssertFalse(mirror.children.contains {
            String(describing: $0.value).contains(passwordSentinel)
        })
        let mirrorChildren = Array(mirror.children)
        XCTAssertEqual(String(describing: mirrorChildren[1].value), "<redacted>")
    }

    func testServiceConnectionDescriptionsRedactEndpointSecrets() {
        let userinfoSentinel = "service-userinfo-sentinel-secret"
        let querySentinel = "service-query-sentinel-secret"
        let endpoint = ServiceEndpoint(
            baseURL: URL(string: "https://user:\(userinfoSentinel)@service.example.test/root?token=\(querySentinel)")!
        )
        let capabilitySentinel = "credential-capability-sentinel-secret"
        let connection = ServiceConnection(
            connectionID: ConnectionID(rawValue: "configured"),
            endpoint: endpoint,
            credentialCapability: TestCredentialCapability(safeDescription: capabilitySentinel)
        )

        let endpointRepresentations = [
            endpoint.description,
            endpoint.debugDescription,
            String(describing: endpoint),
            String(reflecting: endpoint),
            String(reflecting: Mirror(reflecting: endpoint))
        ]
        for representation in endpointRepresentations {
            XCTAssertFalse(representation.contains(userinfoSentinel), representation)
            XCTAssertFalse(representation.contains(querySentinel), representation)
        }

        let connectionRepresentations = [
            connection.description,
            connection.debugDescription,
            String(describing: connection),
            String(reflecting: connection),
            String(reflecting: Mirror(reflecting: connection))
        ]
        for representation in connectionRepresentations {
            XCTAssertFalse(representation.contains(userinfoSentinel), representation)
            XCTAssertFalse(representation.contains(querySentinel), representation)
            XCTAssertFalse(representation.contains(capabilitySentinel), representation)
        }

        XCTAssertTrue(connection.description.contains("endpoint: <redacted>"))
        XCTAssertTrue(connection.description.contains("credentials: <redacted>"))

        let endpointMirror = Mirror(reflecting: endpoint)
        XCTAssertFalse(endpointMirror.children.contains {
            let value = String(describing: $0.value)
            return value.contains(userinfoSentinel) || value.contains(querySentinel)
        })

        let connectionMirror = Mirror(reflecting: connection)
        XCTAssertFalse(connectionMirror.children.contains {
            let value = String(describing: $0.value)
            return value.contains(userinfoSentinel) || value.contains(querySentinel)
        })
        XCTAssertFalse(String(reflecting: connectionMirror).contains("ServiceEndpoint"))
        XCTAssertFalse(String(reflecting: connectionMirror).contains("TestCredentialCapability"))
        XCTAssertFalse(connectionMirror.children.contains {
            String(describing: $0.value).contains(capabilitySentinel)
        })
    }

    func testPresentationContractContainsNoTransportDetails() {
        let state = PresentationState(
            title: "Workspace",
            locationID: LocationID(rawValue: "location"),
            selectedDirectory: URL(filePath: "/chosen")
        )
        XCTAssertEqual(state.selectedDirectory?.path, "/chosen")
    }
}

private struct TestCredentialCapability: CredentialCapability {
    let safeDescription: String

    init(safeDescription: String = "test-credential-capability") {
        self.safeDescription = safeDescription
    }

    func credential(for connection: ConnectionID) async throws -> ServiceCredential? {
        ServiceCredential(username: "alice", password: "transient-secret")
    }
}

private actor CapturingHTTPTransport: HTTPTransport {
    private(set) var captured: (connection: ServiceConnection, request: HTTPRequest)?

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        captured = (connection, request)
        return HTTPResponse(statusCode: 200, headers: [:], body: Data())
    }
}
