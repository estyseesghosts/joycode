import Foundation
import XCTest
@testable import Joycode

// MARK: - Prompt adapter tests (PromptAPI, API-only slice)

final class PromptAPITests: XCTestCase {
    private static let sessionID = SessionID(rawValue: "ses-1")
    private static let messageID = "msg_stable-identity-1"

    private func connection() -> ServiceConnection {
        ServiceConnection(
            connectionID: ConnectionID(rawValue: "prompt-test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            credentialCapability: PromptCredentials()
        )
    }

    private func request(text: String = "hello") -> PromptRequest {
        PromptRequest(sessionID: Self.sessionID, messageID: Self.messageID, text: text)
    }

    private func successBody(
        id: String = PromptAPITests.messageID,
        sessionID: String = PromptAPITests.sessionID.rawValue,
        type: String = "user",
        created: Double = 1_700_000_000_000,
        text: String = "hello",
        delivery: String = "steer",
        extra: String = ""
    ) -> Data {
        Data(
            """
            {"data":{"id":"\(id)","sessionID":"\(sessionID)","type":"\(type)",\
            "time":{"created":\(created)},"payload":{"text":\(jsonString(text))},\
            "delivery":"\(delivery)"\(extra)}}
            """.utf8
        )
    }

    // 1. testPromptRequestUsesPostPathAndExactBody
    func testPromptRequestUsesPostPathAndExactBody() throws {
        let httpRequest = PromptAPI.promptRequest(request(text: "line one\nline two ✓"))
        XCTAssertEqual(httpRequest.method, .post)
        XCTAssertEqual(httpRequest.relativePath, "/api/session/ses-1/prompt")
        XCTAssertTrue(httpRequest.queryItems.isEmpty)
        let body = try XCTUnwrap(httpRequest.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "text"], "Body must contain exactly id + text: no agent/model/parts fields")
        XCTAssertEqual(json["id"] as? String, Self.messageID)
        XCTAssertEqual(json["text"] as? String, "line one\nline two ✓", "Unicode/multiline text must round-trip exactly")
    }

    // 2. testAdmittedSuccessValidatesIdentityAndText
    func testAdmittedSuccessValidatesIdentityAndText() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(delivery: "queue"))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let requests = await transport.requests
        let connections = await transport.connections
        XCTAssertEqual(requests.count, 1, "Prompt must be sent exactly once: no retry, no readback")
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?.connectionID.rawValue, "prompt-test", "Transport auth must flow through the captured connection")
        if case .admitted(let message) = result {
            XCTAssertEqual(message.id, Self.messageID)
            XCTAssertEqual(message.sessionID, Self.sessionID.rawValue)
            XCTAssertEqual(message.text, "hello")
            XCTAssertEqual(message.delivery, .queue)
        } else {
            XCTFail("Expected admitted, got \(result)")
        }
    }

    // 3. testMismatchedIDIsUnknown
    func testMismatchedIDIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(id: "msg_other"))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown = result { } else { XCTFail("An ID mismatch must stay ambiguous, got \(result)") }
    }

    // 4. testMismatchedSessionIDIsUnknown
    func testMismatchedSessionIDIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(sessionID: "ses-other"))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown = result { } else { XCTFail("A session mismatch must stay ambiguous, got \(result)") }
    }

    // 5. testMismatchedTextIsUnknown
    func testMismatchedTextIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(text: "different text"))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown = result { } else { XCTFail("A text mismatch must stay ambiguous, got \(result)") }
    }

    // 6. testWrongTypeIsUnknown
    func testWrongTypeIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(type: "assistant"))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown = result { } else { XCTFail("A non-user success must stay ambiguous, got \(result)") }
    }

    // 7. testMalformedSuccessBodyIsUnknown
    func testMalformedSuccessBodyIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(200, Data("not-json".utf8))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown(let error) = result {
            XCTAssertEqual(error, .malformedResponse)
        } else {
            XCTFail("A malformed success must stay ambiguous, got \(result)")
        }
    }

    // 8. testSuccessMissingRequiredFieldIsUnknown
    func testSuccessMissingRequiredFieldIsUnknown() async throws {
        let body = Data(#"{"data":{"id":"\#(Self.messageID)","sessionID":"\#(Self.sessionID.rawValue)","type":"user","time":{"created":1700000000000},"payload":{"text":"hello"}}}"#.utf8)
        let transport = PromptTestTransport(responses: [(200, body)])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown = result { } else { XCTFail("A success missing delivery must stay ambiguous, got \(result)") }
    }

    // 9. testDeclaredRejectionsAreRejectedWithoutRetry
    func testDeclaredRejectionsAreRejectedWithoutRetry() async throws {
        let cases: [(Int, PromptAPIError)] = [
            (400, .backend(statusCode: 400)),
            (401, .unauthorized),
            (404, .notFound),
            (409, .conflict),
        ]
        for (status, expected) in cases {
            let transport = PromptTestTransport(responses: [(status, Data())])
            let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "Status \(status) must send exactly once")
            if case .rejected(let error) = result {
                XCTAssertEqual(error, expected, "Status \(status)")
            } else {
                XCTFail("Status \(status) must be a declared rejection, got \(result)")
            }
        }
    }

    // 10. testUnknownServerErrorIsUnknown
    func testUnknownServerErrorIsUnknown() async throws {
        let transport = PromptTestTransport(responses: [(500, Data())])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown(let error) = result {
            XCTAssertEqual(error, .backend(statusCode: 500))
        } else {
            XCTFail("An undeclared 5xx must stay ambiguous, got \(result)")
        }
    }

    // 11. testUnexpected2xxIsUnknown
    func testUnexpected2xxIsUnknown() async throws {
        for status in [201, 204] {
            let transport = PromptTestTransport(responses: [(status, Data("{}".utf8))])
            let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "Status \(status) must send exactly once")
            if case .unknown = result { } else { XCTFail("Status \(status) is not the verified 200 admission, got \(result)") }
        }
    }

    // 12. testTransportFailureIsUnknown
    func testTransportFailureIsUnknown() async throws {
        let transport = PromptTestTransport(error: HTTPTransportError.transport("down"))
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        if case .unknown(let error) = result {
            XCTAssertEqual(error, .requestFailed)
        } else {
            XCTFail("A transport failure must stay ambiguous, got \(result)")
        }
    }

    // 13. testTransportCancellationRethrows
    func testTransportCancellationRethrows() async {
        let transport = PromptTestTransport(error: CancellationError())
        do {
            _ = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
            XCTFail("Cancellation must be rethrown, not represented")
        } catch is CancellationError {
            // Expected: cancellation after dispatch cannot prove rejection.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    // 14. testDeclaredRejectionClassification
    func testDeclaredRejectionClassification() {
        XCTAssertTrue(PromptAPI.isDeclaredRejection(.backend(statusCode: 400)))
        XCTAssertTrue(PromptAPI.isDeclaredRejection(.unauthorized))
        XCTAssertTrue(PromptAPI.isDeclaredRejection(.notFound))
        XCTAssertTrue(PromptAPI.isDeclaredRejection(.conflict))
        XCTAssertFalse(PromptAPI.isDeclaredRejection(.backend(statusCode: 500)))
        XCTAssertFalse(PromptAPI.isDeclaredRejection(.malformedResponse))
        XCTAssertFalse(PromptAPI.isDeclaredRejection(.requestFailed))
        XCTAssertFalse(PromptAPI.isDeclaredRejection(.notConnected))
    }

    // 15. testSuccessToleratesExtraFields
    func testSuccessToleratesExtraFields() async throws {
        let transport = PromptTestTransport(responses: [(200, successBody(extra: #","agent":"build","model":{"id":"m","providerID":"p"},"unknown":true"#))])
        let result = try await PromptAPI(transport: transport).send(connection: connection(), request: request())
        if case .admitted(let message) = result {
            XCTAssertEqual(message.id, Self.messageID)
        } else {
            XCTFail("Extra success fields must be tolerated, got \(result)")
        }
    }
}

private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value])
    var text = String(decoding: data, as: UTF8.self)
    text.removeFirst()
    text.removeLast()
    return text
}

private struct PromptCredentials: CredentialCapability {
    var safeDescription: String { "prompt-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private actor PromptTestTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private(set) var connections: [ServiceConnection] = []
    private var responses: [(Int, Data)]
    private let error: (any Error)?

    init(responses: [(Int, Data)] = [], error: (any Error)? = nil) {
        self.responses = responses
        self.error = error
    }

    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        connections.append(connection)
        if let error { throw error }
        guard !responses.isEmpty else { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let (status, body) = responses.removeFirst()
        return HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}
