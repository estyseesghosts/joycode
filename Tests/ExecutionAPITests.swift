import Foundation
import XCTest
@testable import Joycode

// MARK: - Execution adapter tests (ExecutionAPI, R09 API-only slice)

final class ExecutionAPITests: XCTestCase {
    private func connection() -> ServiceConnection {
        ServiceConnection(
            connectionID: ConnectionID(rawValue: "execution-test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            credentialCapability: ExecutionCredentials()
        )
    }

    // MARK: Request construction

    func testActiveRequestUsesGetActivePath() {
        let request = ExecutionAPI.activeRequest()
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/session/active")
        XCTAssertTrue(request.queryItems.isEmpty)
        XCTAssertNil(request.body)
    }

    func testInterruptRequestUsesPostPathWithResumeFalseAndNoBody() {
        let request = ExecutionAPI.interruptRequest(sessionID: SessionID(rawValue: "ses-1"))
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/interrupt")
        XCTAssertEqual(request.queryItems, [.init(name: "resume", value: "false")])
        XCTAssertNil(request.body, "Interrupt sends no body: resume rides on the query only")
    }

    func testInterruptQueryRoundTripsVerbatimThroughURLComposition() throws {
        let url = try HTTPRequestBuilder.makeURL(
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            request: ExecutionAPI.interruptRequest(sessionID: SessionID(rawValue: "ses-1"))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/session/ses-1/interrupt")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "resume", value: "false")])
    }

    // MARK: Active decoding

    func testActiveDecodesRunningSetAndSendsOnce() async throws {
        let body = Data(#"{"data":{"ses-1":{"type":"running"},"ses-2":{"type":"running"}}}"#.utf8)
        let transport = ExecutionTestTransport(responses: [(200, body)])
        let active = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
        XCTAssertEqual(active, [SessionID(rawValue: "ses-1"), SessionID(rawValue: "ses-2")])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].relativePath, "/api/session/active")
    }

    func testActiveEmptyMapIsEmptySet() async throws {
        let transport = ExecutionTestTransport(responses: [(200, Data(#"{"data":{}}"#.utf8))])
        let active = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
        XCTAssertTrue(active.isEmpty)
    }

    func testActiveToleratesExtraFields() async throws {
        let body = Data(#"{"data":{"ses-keep":{"type":"running","extra":true}}}"#.utf8)
        let transport = ExecutionTestTransport(responses: [(200, body)])
        let active = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
        XCTAssertEqual(active, [SessionID(rawValue: "ses-keep")])
    }

    func testActiveMalformedEnvelopeThrows() async {
        for body in [Data("not-json".utf8), Data(#"{"data":[1,2]}"#.utf8), Data(#"{}"#.utf8), Data(#"{"data":{"ses-1":{}}}"#.utf8), Data(#"{"data":{"ses-1":{"type":"future-kind"}}}"#.utf8), Data(#"{"data":{"invalid":{"type":"running"}}}"#.utf8)] {
            let transport = ExecutionTestTransport(responses: [(200, body)])
            do {
                _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
                XCTFail("expected malformedResponse")
            } catch let error as ExecutionAPIError {
                XCTAssertEqual(error, .malformedResponse)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testActiveMixedValidAndInvalidEntryFailsEntireRead() async {
        // One invalid entry must fail the whole read rather than disappearing
        // from the map and falsely confirming inactivity.
        let body = Data(#"{"data":{"ses-valid":{"type":"running"},"ses-bad":{"type":"future-kind"}}}"#.utf8)
        let transport = ExecutionTestTransport(responses: [(200, body)])
        do {
            _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
            XCTFail("expected malformedResponse for the mixed map")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1, "A malformed map must not be retried")
    }

    // MARK: Active status mapping

    func testActiveStatusMapping() async {
        for (status, expected) in [
            (400, ExecutionAPIError.backend(statusCode: 400)),
            (401, ExecutionAPIError.unauthorized),
            (404, ExecutionAPIError.notFound),
            (500, ExecutionAPIError.backend(statusCode: 500)),
        ] {
            let transport = ExecutionTestTransport(responses: [(status, Data())])
            do {
                _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
                XCTFail("expected error for status \(status)")
            } catch let error as ExecutionAPIError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "Status \(status) must send exactly once: never retry")
        }
    }

    func testActiveUnexpected201IsNotAccepted() async {
        let transport = ExecutionTestTransport(responses: [(201, Data(#"{"data":{}}"#.utf8))])
        do {
            _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
            XCTFail("expected backend error for 201")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .backend(statusCode: 201))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testActiveUnexpected409IsBusy() async {
        // 409 is undeclared for the active read too; the shared mapping handles
        // it conservatively rather than treating it as success or a rejection.
        let transport = ExecutionTestTransport(responses: [(409, Data())])
        do {
            _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
            XCTFail("expected busy for 409")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .busy)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    // MARK: Interrupt decoding

    func testInterruptTrueIsAcceptance() async throws {
        let transport = ExecutionTestTransport(responses: [(200, Data(#"{"interrupted":true}"#.utf8))])
        let interrupted = try await ExecutionAPI(transport: transport).interrupt(
            connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
        XCTAssertTrue(interrupted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].relativePath, "/api/session/ses-1/interrupt")
    }

    func testInterruptFalseIsValidAnswerNotError() async throws {
        // An idle session may report false: async acceptance, not stop proof.
        let transport = ExecutionTestTransport(responses: [(200, Data(#"{"interrupted":false,"extra":1}"#.utf8))])
        let interrupted = try await ExecutionAPI(transport: transport).interrupt(
            connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
        XCTAssertFalse(interrupted)
    }

    func testInterruptMalformedBodyThrows() async {
        for body in [Data("not-json".utf8), Data(#"{}"#.utf8), Data(#"{"interrupted":"yes"}"#.utf8)] {
            let transport = ExecutionTestTransport(responses: [(200, body)])
            do {
                _ = try await ExecutionAPI(transport: transport).interrupt(
                    connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
                XCTFail("expected malformedResponse")
            } catch let error as ExecutionAPIError {
                XCTAssertEqual(error, .malformedResponse)
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "A malformed success must stay ambiguous: never retry")
        }
    }

    // MARK: Interrupt status mapping

    func testInterruptDeclaredErrors() async {
        for (status, expected) in [
            (400, ExecutionAPIError.backend(statusCode: 400)),
            (401, ExecutionAPIError.unauthorized),
            (404, ExecutionAPIError.notFound),
        ] {
            let transport = ExecutionTestTransport(responses: [(status, Data())])
            do {
                _ = try await ExecutionAPI(transport: transport).interrupt(
                    connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
                XCTFail("expected error for status \(status)")
            } catch let error as ExecutionAPIError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "Status \(status) must send exactly once")
        }
    }

    func testInterruptUnexpected409IsBusy() async {
        let transport = ExecutionTestTransport(responses: [(409, Data())])
        do {
            _ = try await ExecutionAPI(transport: transport).interrupt(
                connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
            XCTFail("expected busy for 409")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .busy, "409 is undeclared: handle conservatively as busy")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testInterruptUnknownServerErrorIsBackend() async {
        let transport = ExecutionTestTransport(responses: [(500, Data())])
        do {
            _ = try await ExecutionAPI(transport: transport).interrupt(
                connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
            XCTFail("expected backend error")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .backend(statusCode: 500))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInterruptUnexpected201IsNotAccepted() async {
        let transport = ExecutionTestTransport(responses: [(201, Data(#"{"interrupted":true}"#.utf8))])
        do {
            _ = try await ExecutionAPI(transport: transport).interrupt(
                connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
            XCTFail("expected backend error for 201")
        } catch let error as ExecutionAPIError {
            XCTAssertEqual(error, .backend(statusCode: 201))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Transport behavior

    func testTransportFailureIsRequestFailed() async {
        for operation in ["active", "interrupt"] {
            let transport = ExecutionTestTransport(responses: [], failure: HTTPTransportError.transport("down"))
            do {
                if operation == "active" {
                    _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
                } else {
                    _ = try await ExecutionAPI(transport: transport).interrupt(
                        connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
                }
                XCTFail("expected requestFailed for \(operation)")
            } catch let error as ExecutionAPIError {
                XCTAssertEqual(error, .requestFailed, "\(operation): unknown transport stays ambiguous")
            } catch {
                XCTFail("unexpected error \(error)")
            }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1, "\(operation): never retry an ambiguous failure")
        }
    }

    func testCancellationPropagates() async {
        for operation in ["active", "interrupt"] {
            let transport = ExecutionTestTransport(responses: [], failure: CancellationError())
            do {
                if operation == "active" {
                    _ = try await ExecutionAPI(transport: transport).activeSessions(connection: connection())
                } else {
                    _ = try await ExecutionAPI(transport: transport).interrupt(
                        connection: connection(), sessionID: SessionID(rawValue: "ses-1"))
                }
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
        XCTAssertTrue(ExecutionAPI.isDeclaredRejection(.backend(statusCode: 400)))
        XCTAssertTrue(ExecutionAPI.isDeclaredRejection(.unauthorized))
        XCTAssertTrue(ExecutionAPI.isDeclaredRejection(.notFound))
        XCTAssertFalse(ExecutionAPI.isDeclaredRejection(.busy), "Unexpected 409 is busy, not a declared rejection")
        XCTAssertFalse(ExecutionAPI.isDeclaredRejection(.backend(statusCode: 500)))
        XCTAssertFalse(ExecutionAPI.isDeclaredRejection(.malformedResponse))
        XCTAssertFalse(ExecutionAPI.isDeclaredRejection(.requestFailed))
        XCTAssertFalse(ExecutionAPI.isDeclaredRejection(.notConnected))
    }
}

// MARK: - Test doubles

private struct ExecutionCredentials: CredentialCapability {
    var safeDescription: String { "execution-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private actor ExecutionTestTransport: HTTPTransport {
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
