import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript contract adapter tests (TranscriptAPI, R07a)

final class TranscriptAPITests: XCTestCase {
    private func connection() -> ServiceConnection {
        ServiceConnection(
            connectionID: ConnectionID(rawValue: "transcript-test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            credentialCapability: TranscriptCredentials()
        )
    }

    // MARK: Request construction

    func testHistoryRequestUsesSessionMessagePath() {
        let request = TranscriptAPI.historyRequest(
            sessionID: SessionID(rawValue: "ses-1"),
            query: TranscriptQuery(limit: nil, order: nil, cursor: nil)
        )
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/message")
        XCTAssertTrue(request.queryItems.isEmpty)
        XCTAssertNil(request.body)
    }

    func testDefaultQueryIsDescLimit50() {
        XCTAssertEqual(TranscriptQuery.defaultPage.limit, 50)
        XCTAssertEqual(TranscriptQuery.defaultPage.order, .desc)
        XCTAssertNil(TranscriptQuery.defaultPage.cursor)
        let items = TranscriptAPI.historyRequest(sessionID: SessionID(rawValue: "ses-1")).queryItems
        XCTAssertEqual(items, [.init(name: "limit", value: "50"), .init(name: "order", value: "desc")])
    }

    func testHistoryRequestUsesOnlyPagingQueryItems() {
        let request = TranscriptAPI.historyRequest(
            sessionID: SessionID(rawValue: "ses-1"),
            query: TranscriptQuery(limit: 25, order: .asc, cursor: nil)
        )
        XCTAssertEqual(request.queryItems, [.init(name: "limit", value: "25"), .init(name: "order", value: "asc")])
        for item in request.queryItems {
            XCTAssertTrue(["limit", "order", "cursor"].contains(item.name), "No legacy parts parameter allowed: \(item.name)")
        }
        XCTAssertFalse(request.queryItems.contains(where: { $0.name == "parts" }))
    }

    func testLimitBoundsAreValidated() {
        XCTAssertNoThrow(try TranscriptAPI.validate(TranscriptQuery(limit: 1, order: nil, cursor: nil)))
        XCTAssertNoThrow(try TranscriptAPI.validate(TranscriptQuery(limit: 200, order: nil, cursor: nil)))
        for limit in [0, -1, 201, 10_000] {
            XCTAssertThrowsError(try TranscriptAPI.validate(TranscriptQuery(limit: limit, order: nil, cursor: nil))) {
                XCTAssertEqual($0 as? TranscriptQueryError, .limitOutOfRange(limit))
            }
        }
        XCTAssertNoThrow(try TranscriptAPI.validate(TranscriptQuery(limit: nil, order: nil, cursor: nil)))
    }

    func testOrderCannotCoexistWithCursor() {
        XCTAssertThrowsError(
            try TranscriptAPI.validate(TranscriptQuery(limit: 50, order: .desc, cursor: "opaque"))
        ) {
            XCTAssertEqual($0 as? TranscriptQueryError, .orderWithCursor)
        }
        XCTAssertNoThrow(try TranscriptAPI.validate(TranscriptQuery(limit: 50, order: .desc, cursor: nil)))
        XCTAssertNoThrow(try TranscriptAPI.validate(TranscriptQuery(limit: 50, order: nil, cursor: "opaque")))
    }

    func testInvalidQueryFailsBeforeSending() async throws {
        let transport = TranscriptTestTransport(responses: [(200, Data())])
        do {
            _ = try await TranscriptAPI(transport: transport).page(
                connection: connection(),
                sessionID: SessionID(rawValue: "ses-1"),
                query: TranscriptQuery(limit: 50, order: .desc, cursor: "opaque")
            )
            XCTFail("expected invalidQuery")
        } catch let error as TranscriptAPIError {
            XCTAssertEqual(error, .invalidQuery(.orderWithCursor))
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "An invalid query must not be sent")
    }

    func testOpaqueCursorRoundTripsVerbatimThroughURLComposition() throws {
        let cursor = "opaque+cursor/with=special&chars"
        let url = try HTTPRequestBuilder.makeURL(
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!),
            request: TranscriptAPI.historyRequest(
                sessionID: SessionID(rawValue: "ses-1"),
                query: TranscriptQuery(limit: nil, order: nil, cursor: cursor)
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, cursor)
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
            "/api/session/ses-1/message"
        )
    }

    // MARK: Mixed typed content and tool states

    func testMixedTypedContentDecodesInServerOrder() throws {
        let page = try TranscriptPage.decode(Data(mixedHistoryJSON.utf8))
        XCTAssertEqual(page.messages.count, 4)
        XCTAssertEqual(page.messages.map(\.kind), ["user", "assistant", "system", "skill"])
        XCTAssertEqual(page.cursor.next, "next-opaque")
        XCTAssertNil(page.cursor.previous)

        guard case .user(let user) = page.messages[0] else { return XCTFail("expected user") }
        XCTAssertEqual(user.id, "msg-user-1")
        XCTAssertEqual(user.text, "hello")

        guard case .assistant(let assistant) = page.messages[1] else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.id, "msg-asst-1")
        XCTAssertEqual(assistant.agent, "build")
        XCTAssertEqual(assistant.model, TranscriptModelRef(id: "claude", providerID: "anthropic", variant: nil))
        XCTAssertNil(assistant.finish)
        XCTAssertNil(assistant.error)
        XCTAssertNil(assistant.completed)
        XCTAssertEqual(assistant.content.count, 4)
        XCTAssertEqual(assistant.content[0], .text("answering"))
        XCTAssertEqual(assistant.content[1], .reasoning("thinking"))
        guard case .tool(let streaming) = assistant.content[2] else { return XCTFail("expected tool") }
        XCTAssertEqual(streaming.id, "tool-1")
        XCTAssertEqual(streaming.name, "read")
        if case .streaming(let input) = streaming.state {
            XCTAssertEqual(input, "partial-args")
        } else { XCTFail("expected streaming state") }
        guard case .tool(let completed) = assistant.content[3] else { return XCTFail("expected tool") }
        if case .completed(_, let content, _) = completed.state {
            XCTAssertEqual(content, [.text("file-bytes"), .file(uri: "file:///w/out.txt", mime: "text/plain", name: "out.txt")])
        } else { XCTFail("expected completed state") }

        // Scoped identity: positional for text/reasoning, tool-scoped otherwise.
        XCTAssertEqual(assistant.contentID(at: 0), .positional(messageID: "msg-asst-1", index: 0))
        XCTAssertEqual(assistant.contentID(at: 1), .positional(messageID: "msg-asst-1", index: 1))
        XCTAssertEqual(assistant.contentID(at: 2), .tool(messageID: "msg-asst-1", toolID: "tool-1"))
        XCTAssertNil(assistant.contentID(at: 9))
    }

    func testRunningCompletedErrorToolStates() throws {
        let page = try TranscriptPage.decode(Data(toolStatesJSON.utf8))
        XCTAssertEqual(page.messages.count, 1)
        guard case .assistant(let assistant) = page.messages[0] else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.content.count, 3)

        guard case .tool(let running) = assistant.content[0] else { return XCTFail("expected tool") }
        if case .running(let input, let metadata) = running.state {
            XCTAssertEqual(input.field("cmd")?.stringValue, "ls")
            XCTAssertEqual(metadata.field("started")?.stringValue, "yes")
        } else { XCTFail("expected running state") }

        guard case .tool(let completed) = assistant.content[1] else { return XCTFail("expected tool") }
        if case .completed(let input, let content, _) = completed.state {
            XCTAssertEqual(input.field("cmd")?.stringValue, "ls")
            XCTAssertEqual(content, [.text("ok")])
        } else { XCTFail("expected completed state") }

        guard case .tool(let failed) = assistant.content[2] else { return XCTFail("expected tool") }
        if case .error(let input, let error, let content, _) = failed.state {
            XCTAssertEqual(input.field("cmd")?.stringValue, "rm")
            XCTAssertEqual(error.type, "ToolError")
            XCTAssertEqual(error.message, "denied")
            XCTAssertEqual(content, [.text("partial")])
        } else { XCTFail("expected error state") }
    }

    func testErrorToolWithoutContentDecodesWithNilContent() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t1","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{},"error":{"type":"E","message":"bad", "status": 500}}}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        guard case .tool(let tool) = assistant.content.first else { return XCTFail("expected tool") }
        if case .error(_, let error, let content, _) = tool.state {
            XCTAssertEqual(error.type, "E")
            XCTAssertEqual(error.status, 500)
            XCTAssertNil(content)
        } else { XCTFail("expected error state") }
    }

    func testFlatToolStateIsNotAccepted() throws {
        // The pinned contract nests tool state in a `state` object
        // discriminated by `status`; the legacy flat string is malformed and
        // must fall back to per-item opaque, preserving siblings.
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t1","name":"n","state":"running","time":{"created":1700000000},"input":{"cmd":"ls"},"metadata":{"started":"yes"}},{"type":"text","text":"kept"}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.content.count, 2)
        guard case .opaque(let opaque) = assistant.content[0] else { return XCTFail("expected opaque content") }
        XCTAssertEqual(opaque.kind, "tool")
        XCTAssertEqual(opaque.reason, "malformed-content")
        XCTAssertEqual(assistant.content[1], .text("kept"))
    }

    func testNestedToolStatesAllFourDecode() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t-stream","name":"n","time":{"created":1700000000},"state":{"status":"streaming","input":"partial"}},{"type":"tool","id":"t-run","name":"n","time":{"created":1700000000},"state":{"status":"running","input":{},"metadata":{}}},{"type":"tool","id":"t-done","name":"n","time":{"created":1700000000},"state":{"status":"completed","input":{},"content":[{"type":"text","text":"ok"}]}},{"type":"tool","id":"t-err","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{},"error":{"type":"E","message":"bad"}}}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.content.count, 4)
        guard case .tool(let streaming) = assistant.content[0] else { return XCTFail("expected tool") }
        if case .streaming(let input) = streaming.state {
            XCTAssertEqual(input, "partial")
        } else { XCTFail("expected streaming state") }
        guard case .tool(let running) = assistant.content[1] else { return XCTFail("expected tool") }
        if case .running = running.state {} else { XCTFail("expected running state") }
        guard case .tool(let completed) = assistant.content[2] else { return XCTFail("expected tool") }
        if case .completed(_, let content, _) = completed.state {
            XCTAssertEqual(content, [.text("ok")])
        } else { XCTFail("expected completed state") }
        guard case .tool(let failed) = assistant.content[3] else { return XCTFail("expected tool") }
        if case .error(_, let error, let content, _) = failed.state {
            XCTAssertEqual(error.type, "E")
            XCTAssertNil(error.status)
            XCTAssertNil(content)
        } else { XCTFail("expected error state") }
    }

    func testCompletedAndErrorMetadataPreserved() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t-done","name":"n","time":{"created":1700000000},"state":{"status":"completed","input":{},"content":[{"type":"text","text":"ok"}],"metadata":{"elapsed":"fast"}}},{"type":"tool","id":"t-err","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{},"error":{"type":"E","message":"bad"},"metadata":{"elapsed":"slow"}}}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        guard case .tool(let completed) = assistant.content.first else { return XCTFail("expected tool") }
        if case .completed(_, _, let metadata) = completed.state {
            XCTAssertEqual(metadata?.field("elapsed")?.stringValue, "fast")
        } else { XCTFail("expected completed state") }
        guard case .tool(let failed) = assistant.content.last else { return XCTFail("expected tool") }
        if case .error(_, _, _, let metadata) = failed.state {
            XCTAssertEqual(metadata?.field("elapsed")?.stringValue, "slow")
        } else { XCTFail("expected error state") }
    }

    func testStructuredErrorStatusMustBeInteger100To599() throws {
        // Out-of-range, fractional, and non-numeric statuses are malformed;
        // the item falls back to per-item opaque, preserving siblings.
        for status in ["99", "600", "1.5", "\"500\"", "true"] {
            let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t1","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{},"error":{"type":"E","message":"bad","status":\#(status)}}},{"type":"text","text":"kept"}]}],"cursor":{}}"#
            let page = try TranscriptPage.decode(Data(json.utf8))
            guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
            XCTAssertEqual(assistant.content.count, 2, "status \(status) must not decode")
            guard case .opaque(let opaque) = assistant.content[0] else { return XCTFail("expected opaque content for status \(status)") }
            XCTAssertEqual(opaque.kind, "tool")
            XCTAssertEqual(opaque.reason, "malformed-content")
            XCTAssertEqual(assistant.content[1], .text("kept"))
        }
        // Boundary values are accepted.
        for status in [100, 599] {
            let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t1","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{},"error":{"type":"E","message":"bad","status":\#(status)}}}]}],"cursor":{}}"#
            let page = try TranscriptPage.decode(Data(json.utf8))
            guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
            guard case .tool(let tool) = assistant.content.first else { return XCTFail("expected tool") }
            if case .error(_, let error, _, _) = tool.state {
                XCTAssertEqual(error.status, status)
            } else { XCTFail("expected error state for status \(status)") }
        }
    }

    func testOffEnumAndNonStringFinishFallBackOpaque() throws {
        // `finish` is a fixed enum; an off-enum or non-string value fails the
        // whole record to opaque rather than becoming a false fact, while
        // neighbors are preserved.
        for finish in ["\"done\"", "42"] {
            let json = #"{"data":[{"id":"u1","type":"user","time":{"created":1700000000},"text":"a"},{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"finish":\#(finish),"content":[{"type":"text","text":"dropped"}]},{"id":"u2","type":"user","time":{"created":1700000000},"text":"b"}],"cursor":{}}"#
            let page = try TranscriptPage.decode(Data(json.utf8))
            XCTAssertEqual(page.messages.map(\.kind), ["user", "assistant", "user"], "finish \(finish) must not decode")
            guard case .opaque(let fallback) = page.messages[1] else { return XCTFail("expected opaque for finish \(finish)") }
            XCTAssertEqual(fallback.id, "m1")
            XCTAssertEqual(fallback.kind, "assistant")
            guard case .user(let last) = page.messages[2] else { return XCTFail("expected user") }
            XCTAssertEqual(last.text, "b")
        }
    }

    func testRetainedVariantsPreserveStructuredData() throws {
        let page = try TranscriptPage.decode(Data(variantsJSON.utf8))
        XCTAssertEqual(
            page.messages.map(\.kind),
            ["agent-switched", "model-switched", "location-switched", "shell", "compaction", "idle", "synthetic"]
        )
        guard case .agentSwitched(let variant) = page.messages[0] else { return XCTFail("expected agent-switched") }
        XCTAssertEqual(variant.id, "msg-sw-1")
        XCTAssertEqual(variant.raw.field("agent")?.stringValue, "plan")
        guard case .synthetic(let synthetic) = page.messages[6] else { return XCTFail("expected synthetic") }
        XCTAssertEqual(synthetic.text, "checkpoint")
    }

    // MARK: Unknown/malformed entry fallback

    func testUnknownAndMalformedEntriesFallBackOpaquePreservingNeighbors() throws {
        let page = try TranscriptPage.decode(Data(fallbackJSON.utf8))
        XCTAssertEqual(page.messages.count, 4)
        XCTAssertEqual(page.messages.map(\.kind), ["user", "future-widget", "assistant", "assistant"])

        guard case .user(let user) = page.messages[0] else { return XCTFail("expected user") }
        XCTAssertEqual(user.text, "before")

        // Unknown type tag is retained, not dropped.
        guard case .opaque(let unknown) = page.messages[1] else { return XCTFail("expected opaque") }
        XCTAssertEqual(unknown.kind, "future-widget")
        XCTAssertEqual(unknown.id, "msg-unknown-1")
        XCTAssertEqual(unknown.raw.field("fancy")?.stringValue, "fancy-payload-sentinel")

        // Assistant missing its required model is opaque, not a false fact.
        guard case .opaque(let malformed) = page.messages[2] else { return XCTFail("expected opaque") }
        XCTAssertEqual(malformed.kind, "assistant")
        XCTAssertEqual(malformed.id, "msg-bad-1")

        // A known neighbor after malformed entries still parses.
        guard case .assistant(let assistant) = page.messages[3] else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.id, "msg-good-1")
    }

    func testMalformedToolContentFallsBackOpaquePreservingSiblings() throws {
        // Completed tool with empty content and error tool without an error object.
        let json = #"{"data":[{"id":"u1","type":"user","time":{"created":1700000000},"text":"a"},{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"before"},{"type":"tool","id":"t1","name":"n","time":{"created":1700000000},"state":{"status":"completed","input":{},"content":[]}},{"type":"text","text":"after"}]},{"id":"m2","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t2","name":"n","time":{"created":1700000000},"state":{"status":"error","input":{}}}]},{"id":"u2","type":"user","time":{"created":1700000000},"text":"b"}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        XCTAssertEqual(page.messages.map(\.kind), ["user", "assistant", "assistant", "user"])
        // Malformed tool items are per-item opaque fallbacks; sibling text is preserved.
        guard case .assistant(let first) = page.messages[1] else { return XCTFail("expected assistant") }
        XCTAssertEqual(first.content.count, 3)
        XCTAssertEqual(first.content[0], .text("before"))
        guard case .opaque(let opaque) = first.content[1] else { return XCTFail("expected opaque content") }
        XCTAssertEqual(opaque.kind, "tool")
        XCTAssertEqual(opaque.reason, "malformed-content")
        XCTAssertEqual(first.content[2], .text("after"))
        XCTAssertEqual(first.contentID(at: 0), .positional(messageID: "m1", index: 0))
        XCTAssertEqual(first.contentID(at: 1), .positional(messageID: "m1", index: 1))
        XCTAssertEqual(first.contentID(at: 2), .positional(messageID: "m1", index: 2))
        guard case .assistant(let second) = page.messages[2] else { return XCTFail("expected assistant") }
        XCTAssertEqual(second.content.count, 1)
        guard case .opaque(let secondOpaque) = second.content.first else { return XCTFail("expected opaque content") }
        XCTAssertEqual(secondOpaque.kind, "tool")
        XCTAssertEqual(secondOpaque.reason, "malformed-content")
        guard case .user(let last) = page.messages[3] else { return XCTFail("expected user") }
        XCTAssertEqual(last.text, "b")
    }

    func testStreamingToolWithNonStringInputFallsBackOpaquePreservingSiblings() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"t1","name":"n","time":{"created":1700000000},"state":{"status":"streaming","input":{}}},{"type":"text","text":"kept"}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.content.count, 2)
        guard case .opaque(let opaque) = assistant.content[0] else { return XCTFail("expected opaque content") }
        XCTAssertEqual(opaque.kind, "tool")
        XCTAssertEqual(opaque.reason, "malformed-content")
        XCTAssertEqual(assistant.content[1], .text("kept"))
    }

    func testStringModelFallsBackOpaquePreservingNeighbors() throws {
        // The pinned contract requires `model` to be a Model.Ref object;
        // a legacy string model must not become a false fact.
        let json = #"{"data":[{"id":"u1","type":"user","time":{"created":1700000000},"text":"a"},{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":"m","content":[{"type":"text","text":"dropped"}]},{"id":"u2","type":"user","time":{"created":1700000000},"text":"b"}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        XCTAssertEqual(page.messages.map(\.kind), ["user", "assistant", "user"])
        guard case .opaque(let fallback) = page.messages[1] else { return XCTFail("expected opaque") }
        XCTAssertEqual(fallback.id, "m1")
        XCTAssertEqual(fallback.kind, "assistant")
        guard case .user(let last) = page.messages[2] else { return XCTFail("expected user") }
        XCTAssertEqual(last.text, "b")
    }

    func testUnknownContentTypeFallsBackOpaquePreservingSiblings() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"before"},{"type":"future-part","payload":"future-payload-sentinel"},{"type":"reasoning","text":"after"}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.content.count, 3)
        XCTAssertEqual(assistant.content[0], .text("before"))
        guard case .opaque(let opaque) = assistant.content[1] else { return XCTFail("expected opaque content") }
        XCTAssertEqual(opaque.kind, "future-part")
        XCTAssertEqual(opaque.reason, "unknown-content-type")
        XCTAssertEqual(opaque.raw.field("payload")?.stringValue, "future-payload-sentinel")
        XCTAssertEqual(assistant.content[2], .reasoning("after"))
    }

    func testAssistantErrorFinishAndCompletedArePreserved() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000,"completed":1700000001},"agent":"build","model":{"id":"m","providerID":"p","variant":"v"},"finish":"error","error":{"type":"ProviderError","message":"boom-visible","status":500},"content":[{"type":"text","text":"t"}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        XCTAssertEqual(assistant.model, TranscriptModelRef(id: "m", providerID: "p", variant: "v"))
        XCTAssertEqual(assistant.finish, "error")
        XCTAssertEqual(assistant.completed, 1700000001)
        let error = try XCTUnwrap(assistant.error)
        XCTAssertEqual(error.type, "ProviderError")
        XCTAssertEqual(error.message, "boom-visible")
    }

    func testOpaqueContentDescriptionOmitsRawPayload() throws {
        let json = #"{"data":[{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"future-part","payload":"future-payload-sentinel"}]}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .assistant(let assistant) = page.messages.first else { return XCTFail("expected assistant") }
        guard case .opaque(let opaque) = assistant.content.first else { return XCTFail("expected opaque content") }
        let rendered = String(describing: assistant.content.first!) + String(reflecting: opaque)
        XCTAssertFalse(rendered.contains("future-payload-sentinel"), "Raw content payloads must not render")
        XCTAssertTrue(rendered.contains("future-part"))
    }

    // MARK: Envelope validation

    func testEnvelopeRequiresCursorObject() {
        XCTAssertThrowsError(try TranscriptPage.decode(Data(#"{"data":[]}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptDecodeError, .malformed)
        }
        XCTAssertThrowsError(try TranscriptPage.decode(Data(#"{"data":[],"cursor":null}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptDecodeError, .malformed)
        }
        XCTAssertThrowsError(try TranscriptPage.decode(Data(#"{"cursor":{}}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptDecodeError, .malformed)
        }
        XCTAssertThrowsError(try TranscriptPage.decode(Data("not-json".utf8))) {
            XCTAssertEqual($0 as? TranscriptDecodeError, .malformed)
        }
        XCTAssertThrowsError(try TranscriptPage.decode(Data(#"{"data":{},"cursor":{}}"#.utf8))) {
            XCTAssertEqual($0 as? TranscriptDecodeError, .malformed)
        }
    }

    func testEmptyPageDecodesAndTerminatesPaging() throws {
        let page = try TranscriptPage.decode(Data(#"{"data":[],"cursor":{"previous":"p","next":"n"}}"#.utf8))
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.cursor, TranscriptCursor(previous: "p", next: "n"))
    }

    // MARK: Transport behavior

    func testPageSendsSessionScopedMessageRequest() async throws {
        let body = Data(#"{"data":[],"cursor":{}}"#.utf8)
        let transport = TranscriptTestTransport(responses: [(200, body)])
        let page = try await TranscriptAPI(transport: transport).page(
            connection: connection(),
            sessionID: SessionID(rawValue: "ses-9"),
            query: TranscriptQuery(limit: nil, order: nil, cursor: nil)
        )
        XCTAssertTrue(page.messages.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, .get)
        XCTAssertEqual(requests[0].relativePath, "/api/session/ses-9/message")
    }

    func testStatusMapping() async {
        for (status, expected) in [
            (400, TranscriptAPIError.backend(statusCode: 400)),
            (401, TranscriptAPIError.unauthorized),
            (404, TranscriptAPIError.notFound),
            (500, TranscriptAPIError.backend(statusCode: 500))
        ] {
            let transport = TranscriptTestTransport(responses: [(status, Data())])
            do {
                _ = try await TranscriptAPI(transport: transport).page(
                    connection: connection(),
                    sessionID: SessionID(rawValue: "ses-1")
                )
                XCTFail("expected error for status \(status)")
            } catch let error as TranscriptAPIError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testUnexpected201IsNotAccepted() async {
        // The pinned contract declares exactly 200 for history reads; any
        // other 2xx (e.g. 201) must surface as a backend error, not a page.
        let body = Data(#"{"data":[],"cursor":{}}"#.utf8)
        let transport = TranscriptTestTransport(responses: [(201, body)])
        do {
            _ = try await TranscriptAPI(transport: transport).page(
                connection: connection(),
                sessionID: SessionID(rawValue: "ses-1")
            )
            XCTFail("expected backend error for 201")
        } catch let error as TranscriptAPIError {
            XCTAssertEqual(error, .backend(statusCode: 201))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMalformedBodyMapsToMalformedResponse() async {
        let transport = TranscriptTestTransport(responses: [(200, Data("bad".utf8))])
        do {
            _ = try await TranscriptAPI(transport: transport).page(
                connection: connection(),
                sessionID: SessionID(rawValue: "ses-1")
            )
            XCTFail("expected malformedResponse")
        } catch let error as TranscriptAPIError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCancellationPropagates() async {
        let transport = TranscriptTestTransport(responses: [], failure: CancellationError())
        do {
            _ = try await TranscriptAPI(transport: transport).page(
                connection: connection(),
                sessionID: SessionID(rawValue: "ses-1")
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: Payload safety

    func testDescriptionsNeverRenderPayloadBytes() throws {
        let sentinel = "c2VjcmV0LWJhc2U2NC1ieXRlcw"
        let json = #"{"data":[{"id":"u1","type":"user","time":{"created":1700000000},"text":"visible text","files":[{"name":"a.bin","base64":"\#(sentinel)"}],"extra":true}],"cursor":{}}"#
        let page = try TranscriptPage.decode(Data(json.utf8))
        guard case .user(let user) = page.messages.first else { return XCTFail("expected user") }
        XCTAssertEqual(user.text, "visible text")
        let rendered = String(describing: page.messages.first!) + String(describing: user)
        XCTAssertFalse(rendered.contains(sentinel), "Attachment bytes must never reach display strings")
        XCTAssertFalse(rendered.contains("visible text"), "Message text must not leak through descriptions")
    }

    func testOpaqueDescriptionOmitsRawPayload() throws {
        let page = try TranscriptPage.decode(Data(fallbackJSON.utf8))
        guard case .opaque(let unknown) = page.messages[1] else { return XCTFail("expected opaque") }
        let rendered = String(describing: unknown) + String(reflecting: unknown)
        XCTAssertFalse(rendered.contains("fancy-payload-sentinel"), "Raw variant payloads must not render")
        XCTAssertTrue(rendered.contains("future-widget"))
    }
}

// MARK: - Fixtures

private let mixedHistoryJSON = """
{"data":[
{"id":"msg-user-1","type":"user","time":{"created":1700000000},"text":"hello"},
{"id":"msg-asst-1","type":"assistant","time":{"created":1700000001},"agent":"build","model":{"id":"claude","providerID":"anthropic"},"content":[
{"type":"text","text":"answering"},
{"type":"reasoning","text":"thinking"},
{"type":"tool","id":"tool-1","name":"read","time":{"created":1700000001},"state":{"status":"streaming","input":"partial-args"}},
{"type":"tool","id":"tool-2","name":"write","time":{"created":1700000002},"state":{"status":"completed","input":{"path":"/w"},"content":[{"type":"text","text":"file-bytes"},{"type":"file","uri":"file:///w/out.txt","mime":"text/plain","name":"out.txt"}]}}
]},
{"id":"msg-sys-1","type":"system","time":{"created":1700000003},"text":"sys","extra":{"ignored":true}},
{"id":"msg-skill-1","type":"skill","time":{"created":1700000004},"text":"skilled"}
],"cursor":{"next":"next-opaque"}}
"""

private let toolStatesJSON = """
{"data":[
{"id":"m1","type":"assistant","time":{"created":1700000000},"agent":"build","model":{"id":"m","providerID":"p"},"content":[
{"type":"tool","id":"t-run","name":"exec","time":{"created":1700000000},"state":{"status":"running","input":{"cmd":"ls"},"metadata":{"started":"yes"}}},
{"type":"tool","id":"t-done","name":"exec","time":{"created":1700000001},"state":{"status":"completed","input":{"cmd":"ls"},"content":[{"type":"text","text":"ok"}]}},
{"type":"tool","id":"t-err","name":"exec","time":{"created":1700000002},"state":{"status":"error","input":{"cmd":"rm"},"error":{"type":"ToolError","message":"denied"},"content":[{"type":"text","text":"partial"}]}}
]}
],"cursor":{}}
"""

private let variantsJSON = """
{"data":[
{"id":"msg-sw-1","type":"agent-switched","time":{"created":1700000000},"agent":"plan"},
{"id":"msg-sw-2","type":"model-switched","time":{"created":1700000001},"model":{"id":"m","providerID":"p"}},
{"id":"msg-sw-3","type":"location-switched","time":{"created":1700000002},"location":{"directory":"/w"}},
{"id":"msg-sh-1","type":"shell","time":{"created":1700000003},"command":"ls"},
{"id":"msg-c-1","type":"compaction","time":{"created":1700000004},"summary":"s"},
{"id":"msg-i-1","type":"idle","time":{"created":1700000005}},
{"id":"msg-syn-1","type":"synthetic","time":{"created":1700000006},"text":"checkpoint"}
],"cursor":{}}
"""

private let fallbackJSON = """
{"data":[
{"id":"msg-user-1","type":"user","time":{"created":1700000000},"text":"before"},
{"id":"msg-unknown-1","type":"future-widget","time":{"created":1700000001},"fancy":"fancy-payload-sentinel"},
{"id":"msg-bad-1","type":"assistant","time":{"created":1700000002},"agent":"build","content":[]},
{"id":"msg-good-1","type":"assistant","time":{"created":1700000003},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"after"}]}
],"cursor":{}}
"""

// MARK: - Test doubles

private struct TranscriptCredentials: CredentialCapability {
    var safeDescription: String { "transcript-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private actor TranscriptTestTransport: HTTPTransport {
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
