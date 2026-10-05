import Foundation
import XCTest
@testable import Joycode

// MARK: - Permission adapter tests (PermissionAPI, R10 API-only slice)

final class PermissionAPITests: XCTestCase {
    private static let sessionID = SessionID(rawValue: "ses-1")
    private static let requestID = "per_abc123"

    private func connection() -> ServiceConnection {
        ServiceConnection(
            connectionID: ConnectionID(rawValue: "permission-test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            credentialCapability: PermissionCredentials()
        )
    }

    private func requestJSON(
        id: String = PermissionAPITests.requestID,
        sessionID: String = PermissionAPITests.sessionID.rawValue,
        action: String = "read",
        resources: String = #"["/tmp/file.txt"]"#,
        extra: String = ""
    ) -> String {
        #"{"id":"\#(id)","sessionID":"\#(sessionID)","action":"\#(action)","resources":\#(resources)\#(extra)}"#
    }

    private func fullRequestJSON() -> String {
        requestJSON(extra: #","save":["/tmp/*"],"metadata":{"kind":"edit","count":2},"source":{"type":"tool","messageID":"msg_1","id":"call_1"},"message":"Allow?""#)
    }

    // MARK: Request construction

    func testPendingRequestsRequestUsesGetSessionPath() {
        let request = PermissionAPI.pendingRequestsRequest(sessionID: Self.sessionID)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/permission")
        XCTAssertTrue(request.queryItems.isEmpty)
        XCTAssertNil(request.body)
    }

    func testSingleRequestUsesGetRequestPath() {
        let request = PermissionAPI.permissionRequest(sessionID: Self.sessionID, requestID: Self.requestID)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/permission/per_abc123")
        XCTAssertTrue(request.queryItems.isEmpty)
        XCTAssertNil(request.body)
    }

    func testReplyRequestUsesPostReplyPathWithExactDecisionBody() throws {
        for decision in [PermissionDecision.once, .always, .reject] {
            let request = PermissionAPI.replyRequest(
                sessionID: Self.sessionID, requestID: Self.requestID, decision: decision, message: nil)
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.relativePath, "/api/session/ses-1/permission/per_abc123/reply")
            XCTAssertTrue(request.queryItems.isEmpty)
            let body = try XCTUnwrap(request.body)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(Set(json.keys), ["decision"], "Reply without a message must send exactly {decision}")
            XCTAssertEqual(json["decision"] as? String, decision.rawValue)
        }
    }

    func testReplyRequestIncludesMessageWhenPresent() throws {
        let request = PermissionAPI.replyRequest(
            sessionID: Self.sessionID, requestID: Self.requestID, decision: .once, message: "ok ✓")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["decision", "message"])
        XCTAssertEqual(json["decision"] as? String, "once")
        XCTAssertEqual(json["message"] as? String, "ok ✓", "Unicode message text must round-trip exactly")
    }

    // MARK: Pending list decoding

    func testPendingListDecodesFullRequestsAndSendsOnce() async throws {
        let body = Data(#"{"data":[\#(fullRequestJSON()),\#(requestJSON(id: "per_second"))]}"#.utf8)
        let transport = PermissionTestTransport(responses: [(200, body)])
        let requests = try await PermissionAPI(transport: transport).pendingRequests(
            connection: connection(), sessionID: Self.sessionID)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].id, Self.requestID)
        XCTAssertEqual(requests[0].sessionID, Self.sessionID.rawValue)
        XCTAssertEqual(requests[0].action, "read")
        XCTAssertEqual(requests[0].resources, ["/tmp/file.txt"])
        XCTAssertEqual(requests[0].save, ["/tmp/*"])
        XCTAssertEqual(requests[0].source, PermissionSource(type: "tool", messageID: "msg_1", id: "call_1"))
        XCTAssertEqual(requests[0].message, "Allow?")
        XCTAssertEqual(requests[0].metadata?["kind"], .string("edit"))
        XCTAssertEqual(requests[1].id, "per_second")
        XCTAssertNil(requests[1].save)
        XCTAssertNil(requests[1].source)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "List must send exactly once: no retry, no readback")
        XCTAssertEqual(sent[0].relativePath, "/api/session/ses-1/permission")
    }

    func testPendingListEmptyArrayIsEmpty() async throws {
        let transport = PermissionTestTransport(responses: [(200, Data(#"{"data":[]}"#.utf8))])
        let requests = try await PermissionAPI(transport: transport).pendingRequests(
            connection: connection(), sessionID: Self.sessionID)
        XCTAssertTrue(requests.isEmpty)
    }

    func testPendingListToleratesExtraFields() async throws {
        let extra = #","effect":"ask","unknown":true"#
        let body = Data(#"{"data":[\#(requestJSON(extra: extra))]}"#.utf8)
        let transport = PermissionTestTransport(responses: [(200, body)])
        let requests = try await PermissionAPI(transport: transport).pendingRequests(
            connection: connection(), sessionID: Self.sessionID)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].id, Self.requestID)
    }

    func testPendingListWrongSessionEntryFailsEntireRead() async {
        // One entry owned by another session must fail the whole read rather
        // than disappearing from the pending list.
        let body = Data(#"{"data":[\#(requestJSON()),\#(requestJSON(id: "per_other", sessionID: "ses-other"))]}"#.utf8)
        let transport = PermissionTestTransport(responses: [(200, body)])
        do {
            _ = try await PermissionAPI(transport: transport).pendingRequests(
                connection: connection(), sessionID: Self.sessionID)
            XCTFail("expected malformedResponse for the mixed list")
        } catch let error as PermissionAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1, "An unattributable list must not be retried")
    }

    func testPendingListRejectsUnattributableEntries() async {
        let badBodies = [
            Data(#"{"data":[\#(requestJSON(id: "bad-id"))]}"#.utf8),
            Data(#"{"data":[\#(requestJSON(action: ""))]}"#.utf8),
            Data(#"{"data":[{"id":"per_1","sessionID":"ses-1"}]}"#.utf8),
            Data("not-json".utf8),
            Data(#"{}"#.utf8),
            Data(#"{"data":{"id":"per_1"}}"#.utf8),
        ]
        for body in badBodies {
            let transport = PermissionTestTransport(responses: [(200, body)])
            do {
                _ = try await PermissionAPI(transport: transport).pendingRequests(
                    connection: connection(), sessionID: Self.sessionID)
                XCTFail("expected malformedResponse for \(String(decoding: body, as: UTF8.self))")
            } catch let error as PermissionAPIError {
                XCTAssertEqual(error, .malformedResponse)
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "A malformed list must not be retried")
        }
    }

    func testPendingListRejectsNonToolSource() async {
        let extra = #","source":{"type":"future-kind","messageID":"m","id":"c"}"#
        let body = Data(#"{"data":[\#(requestJSON(extra: extra))]}"#.utf8)
        let transport = PermissionTestTransport(responses: [(200, body)])
        do {
            _ = try await PermissionAPI(transport: transport).pendingRequests(
                connection: connection(), sessionID: Self.sessionID)
            XCTFail("expected malformedResponse for an unattributable source")
        } catch let error as PermissionAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Single read decoding

    func testSingleReadDecodesAndValidatesAttribution() async throws {
        let transport = PermissionTestTransport(responses: [(200, Data(#"{"data":\#(fullRequestJSON())}"#.utf8))])
        let request = try await PermissionAPI(transport: transport).permissionRequest(
            connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID)
        XCTAssertEqual(request.id, Self.requestID)
        XCTAssertEqual(request.sessionID, Self.sessionID.rawValue)
        XCTAssertEqual(request.action, "read")
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].relativePath, "/api/session/ses-1/permission/per_abc123")
    }

    func testSingleReadMismatchedIDIsMalformed() async {
        let transport = PermissionTestTransport(responses: [(200, Data(#"{"data":\#(requestJSON(id: "per_other"))}"#.utf8))])
        do {
            _ = try await PermissionAPI(transport: transport).permissionRequest(
                connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID)
            XCTFail("expected malformedResponse for an ID mismatch")
        } catch let error as PermissionAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testSingleReadMismatchedSessionIsMalformed() async {
        let transport = PermissionTestTransport(responses: [(200, Data(#"{"data":\#(requestJSON(sessionID: "ses-other"))}"#.utf8))])
        do {
            _ = try await PermissionAPI(transport: transport).permissionRequest(
                connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID)
            XCTFail("expected malformedResponse for a session mismatch")
        } catch let error as PermissionAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testSingleReadMalformedSuccessIsUnknownAndNotRetried() async {
        for body in [Data(), Data(#"{"data":{"id":"per_abc123","sessionID":"ses-1"}}"#.utf8)] {
            let transport = PermissionTestTransport(responses: [(200, body)])
            do {
                _ = try await PermissionAPI(transport: transport).permissionRequest(
                    connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID)
                XCTFail("Expected malformed success")
            } catch let error as PermissionAPIError {
                XCTAssertEqual(error, .malformedResponse)
                XCTAssertFalse(PermissionAPI.isDeclaredRejection(error))
            } catch { XCTFail("Unexpected error \(error)") }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    // MARK: Reply

    func testReply204DispatchesOnce() async throws {
        let transport = PermissionTestTransport(responses: [(204, Data())])
        try await PermissionAPI(transport: transport).reply(
            connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID,
            decision: .once, message: nil)
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1, "Reply must dispatch exactly once: no retry")
        XCTAssertEqual(sent[0].relativePath, "/api/session/ses-1/permission/per_abc123/reply")
        let body = try XCTUnwrap(sent[0].body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "once")
    }

    func testReplyRejectWithMessageDispatchesOnce() async throws {
        let transport = PermissionTestTransport(responses: [(204, Data())])
        try await PermissionAPI(transport: transport).reply(
            connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID,
            decision: .reject, message: "no")
        let sent = await transport.requests
        XCTAssertEqual(sent.count, 1)
        let body = try XCTUnwrap(sent[0].body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "reject")
        XCTAssertEqual(json["message"] as? String, "no")
    }

    func testReply204WithBodyIsMalformedAndNeverRetried() async {
        let transport = PermissionTestTransport(responses: [(204, Data(#"{"accepted":true}"#.utf8))])
        do {
            try await PermissionAPI(transport: transport).reply(
                connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID,
                decision: .once, message: nil)
            XCTFail("204 must have no content")
        } catch let error as PermissionAPIError {
            XCTAssertEqual(error, .malformedResponse)
            XCTAssertFalse(PermissionAPI.isDeclaredRejection(error))
        } catch { XCTFail("Unexpected error \(error)") }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    // MARK: Status mapping

    func testDeclaredErrors() async {
        for (status, expected) in [
            (400, PermissionAPIError.backend(statusCode: 400)),
            (401, PermissionAPIError.unauthorized),
            (404, PermissionAPIError.notFound),
            (409, PermissionAPIError.backend(statusCode: 409)),
        ] {
            for operation in ["list", "single", "reply"] {
                let transport = PermissionTestTransport(responses: [(status, Data())])
                do {
                    try await run(operation, transport: transport)
                    XCTFail("expected error for status \(status) on \(operation)")
                } catch let error as PermissionAPIError {
                    XCTAssertEqual(error, expected, "\(operation): status \(status)")
                } catch {
                    XCTFail("unexpected error \(error)")
                }
                let count = await transport.requests.count
                XCTAssertEqual(count, 1, "\(operation): status \(status) must send exactly once")
            }
        }
    }

    func testUnknownServerErrorIsBackend() async {
        for operation in ["list", "single", "reply"] {
            let transport = PermissionTestTransport(responses: [(500, Data())])
            do {
                try await run(operation, transport: transport)
                XCTFail("expected backend error for \(operation)")
            } catch let error as PermissionAPIError {
                XCTAssertEqual(error, .backend(statusCode: 500))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testUnexpected2xxIsNotAccepted() async {
        // Reads require exactly 200; the reply requires exactly 204.
        let cases: [(String, Int, Data)] = [
            ("list", 201, Data(#"{"data":[]}"#.utf8)),
            ("list", 204, Data()),
            ("single", 204, Data()),
            ("reply", 200, Data(#"{}"#.utf8)),
        ]
        for (operation, status, body) in cases {
            let transport = PermissionTestTransport(responses: [(status, body)])
            do {
                try await run(operation, transport: transport)
                XCTFail("expected backend error for \(operation) status \(status)")
            } catch let error as PermissionAPIError {
                XCTAssertEqual(error, .backend(statusCode: status))
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "\(operation): status \(status) must send exactly once")
        }
    }

    func testTransportErrorsMap() async {
        let cases: [(HTTPTransportError, PermissionAPIError)] = [
            (.unauthorized, .unauthorized),
            (.backend(statusCode: 404), .notFound),
            (.backend(statusCode: 400), .backend(statusCode: 400)),
            (.transport("down"), .requestFailed),
            (.protocolError("x"), .requestFailed),
            (.redirectRejected, .requestFailed),
        ]
        for (transportError, expected) in cases {
            for operation in ["list", "single", "reply"] {
                let transport = PermissionTestTransport(responses: [], failure: transportError)
                do {
                    try await run(operation, transport: transport)
                    XCTFail("expected error for \(operation)")
                } catch let error as PermissionAPIError {
                    XCTAssertEqual(error, expected, "\(operation): \(transportError)")
                } catch {
                    XCTFail("unexpected error \(error)")
                }
                let count = await transport.requests.count
                XCTAssertEqual(count, 1, "\(operation): never retry an ambiguous failure")
            }
        }
    }

    func testCancellationPropagates() async {
        for operation in ["list", "single", "reply"] {
            let transport = PermissionTestTransport(responses: [], failure: CancellationError())
            do {
                try await run(operation, transport: transport)
                XCTFail("expected cancellation for \(operation)")
            } catch is CancellationError {
                // Expected: cancellation is rethrown, never represented.
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: Classification

    func testDeclaredRejectionClassification() {
        XCTAssertTrue(PermissionAPI.isDeclaredRejection(.backend(statusCode: 400)))
        XCTAssertTrue(PermissionAPI.isDeclaredRejection(.unauthorized))
        XCTAssertTrue(PermissionAPI.isDeclaredRejection(.notFound))
        XCTAssertFalse(PermissionAPI.isDeclaredRejection(.backend(statusCode: 500)))
        XCTAssertFalse(PermissionAPI.isDeclaredRejection(.backend(statusCode: 409)))
        XCTAssertFalse(PermissionAPI.isDeclaredRejection(.malformedResponse))
        XCTAssertFalse(PermissionAPI.isDeclaredRejection(.requestFailed))
        XCTAssertFalse(PermissionAPI.isDeclaredRejection(.notConnected))
    }

    // MARK: Helpers

    private func run(_ operation: String, transport: PermissionTestTransport) async throws {
        switch operation {
        case "list":
            _ = try await PermissionAPI(transport: transport).pendingRequests(
                connection: connection(), sessionID: Self.sessionID)
        case "single":
            _ = try await PermissionAPI(transport: transport).permissionRequest(
                connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID)
        case "reply":
            try await PermissionAPI(transport: transport).reply(
                connection: connection(), sessionID: Self.sessionID, requestID: Self.requestID,
                decision: .once, message: nil)
        default:
            XCTFail("unknown operation \(operation)")
        }
    }
}

// MARK: - Test doubles

private struct PermissionCredentials: CredentialCapability {
    var safeDescription: String { "permission-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private actor PermissionTestTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private var responses: [(Int, Data)]
    private let failure: (any Error)?

    init(responses: [(Int, Data)], failure: (any Error)? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let (status, body) = responses.removeFirst()
        return HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}
