import Foundation
import XCTest
@testable import Joycode

// MARK: - Transcript presentation identity tests (H07)
//
// Pure tests over `TranscriptPresentation.items`: stable model-supplied
// identity for rows and content. No I/O, no sleeps, no store wiring.

final class TranscriptPresentationIdentityTests: XCTestCase {
    private func model() -> TranscriptModelRef {
        TranscriptModelRef(id: "m", providerID: "openrouter", variant: nil)
    }

    private func assistant(id: String, content: [TranscriptContent] = []) -> TranscriptMessage {
        .assistant(TranscriptAssistantMessage(
            id: id, created: 2000, completed: nil, agent: "build",
            model: model(), finish: nil, error: nil, content: content
        ))
    }

    private func user(id: String) -> TranscriptMessage {
        .user(TranscriptTextMessage(id: id, created: 1000, text: "hi"))
    }

    private func tool(id: String, name: String = "read") -> TranscriptContent {
        .tool(TranscriptToolContent(id: id, name: name, created: 2100, state: .streaming(input: "")))
    }

    // MARK: - Row identity

    func testHistoryMessagesUseHistoryIDs() {
        let messages = [user(id: "u1"), assistant(id: "msg_1")]
        let rows = TranscriptPresentation.items(messages: messages)
        XCTAssertEqual(rows.map(\.id), [.message(historyID: "u1"), .message(historyID: "msg_1")])
        XCTAssertEqual(rows.map(\.message), messages)
    }

    func testIdlessOpaqueMessageUsesSnapshotPosition() {
        let opaque = TranscriptMessage.opaque(TranscriptOpaqueMessage(id: nil, kind: "weird", raw: .null))
        let rows = TranscriptPresentation.items(messages: [user(id: "u1"), opaque])
        XCTAssertEqual(rows[0].id, .message(historyID: "u1"))
        XCTAssertEqual(rows[1].id, .snapshotMessage(index: 1))
        XCTAssertTrue(rows[1].contents.isEmpty)
    }

    func testNonAssistantRowsCarryNoContentsOrLive() {
        let live = TranscriptLiveItem.stream(id: .text(assistantMessageID: "u1", ordinal: 0), text: "x")
        let rows = TranscriptPresentation.items(messages: [user(id: "u1")], live: [live])
        XCTAssertTrue(rows[0].contents.isEmpty)
        XCTAssertTrue(rows[0].liveItems.isEmpty)
    }

    // MARK: - Content identity

    func testToolContentUsesStableToolID() {
        let rows = TranscriptPresentation.items(messages: [
            assistant(id: "msg_1", content: [.text("a"), tool(id: "tool_7"), .reasoning("r")]),
        ])
        XCTAssertEqual(
            rows[0].contents.map(\.id),
            [
                .snapshotContent(messageID: "msg_1", index: 0),
                .tool(messageID: "msg_1", toolID: "tool_7"),
                .snapshotContent(messageID: "msg_1", index: 2),
            ]
        )
    }

    func testOpaqueContentUsesSnapshotContentIdentity() {
        let opaque = TranscriptContent.opaque(TranscriptOpaqueContent(kind: "blob", reason: "unknown-content-type", raw: .null))
        let rows = TranscriptPresentation.items(messages: [assistant(id: "msg_1", content: [opaque])])
        XCTAssertEqual(rows[0].contents.map(\.id), [.snapshotContent(messageID: "msg_1", index: 0)])
    }

    func testPersistedTextIdentityNeverDerivesFromLiveOrdinals() {
        // The persisted text slot sits at content index 0 while a live
        // stream for the same message uses an unrelated ordinal; the two
        // identities must not coincide.
        let rows = TranscriptPresentation.items(messages: [assistant(id: "msg_1", content: [.text("persisted")])])
        XCTAssertEqual(rows[0].contents.map(\.id), [.snapshotContent(messageID: "msg_1", index: 0)])
        let liveID = TranscriptPresentationID.live(.text(assistantMessageID: "msg_1", ordinal: 0))
        XCTAssertNotEqual(rows[0].contents[0].id, liveID)
    }

    // MARK: - Live items

    func testLiveItemsAttachToOwningAssistantInStartOrder() {
        let messages = [assistant(id: "msg_1"), assistant(id: "msg_2")]
        let live = [
            TranscriptLiveItem.stream(id: .text(assistantMessageID: "msg_1", ordinal: 1), text: "b"),
            TranscriptLiveItem.tool(
                id: .tool(assistantMessageID: "msg_2", toolID: "tool_1"),
                name: "read", input: "{}", metadata: nil
            ),
            TranscriptLiveItem.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "a"),
        ]
        let rows = TranscriptPresentation.items(messages: messages, live: live)
        XCTAssertEqual(rows[0].liveItems.map(\.id), [
            .text(assistantMessageID: "msg_1", ordinal: 1),
            .text(assistantMessageID: "msg_1", ordinal: 0),
        ])
        XCTAssertEqual(rows[1].liveItems.map(\.id), [.tool(assistantMessageID: "msg_2", toolID: "tool_1")])
    }

    func testLivePresentationIDsDifferFromPersistedIDsForSameMessage() {
        // Compile-level: `LiveContentID` offers no conversion to or from
        // `TranscriptContentID` (no such API exists on either type), so the
        // only bridge is the `TranscriptPresentationID` enum, where the
        // `.live` case can never equal a persisted case.
        let persisted: Set<TranscriptPresentationID> = [
            .message(historyID: "msg_1"),
            .tool(messageID: "msg_1", toolID: "tool_1"),
            .snapshotContent(messageID: "msg_1", index: 0),
        ]
        let live: Set<TranscriptPresentationID> = [
            .live(.text(assistantMessageID: "msg_1", ordinal: 0)),
            .live(.reasoning(assistantMessageID: "msg_1", ordinal: 0)),
            .live(.tool(assistantMessageID: "msg_1", toolID: "tool_1")),
        ]
        XCTAssertTrue(persisted.isDisjoint(with: live))
    }

    // MARK: - Stability

    func testRepeatedBuildsAreStable() {
        let messages = [
            user(id: "u1"),
            assistant(id: "msg_1", content: [.text("a"), tool(id: "tool_1")]),
        ]
        let live = [TranscriptLiveItem.stream(id: .text(assistantMessageID: "msg_1", ordinal: 0), text: "live")]
        XCTAssertEqual(
            TranscriptPresentation.items(messages: messages, live: live),
            TranscriptPresentation.items(messages: messages, live: live)
        )
    }

    func testAppendedMessagesKeepEarlierRowIDs() {
        let first = [user(id: "u1"), assistant(id: "msg_1")]
        let before = TranscriptPresentation.items(messages: first)
        let after = TranscriptPresentation.items(messages: first + [user(id: "u2")])
        XCTAssertEqual(Array(after.prefix(2).map(\.id)), before.map(\.id))
        XCTAssertEqual(after[2].id, .message(historyID: "u2"))
    }

    func testAppendedContentKeepsEarlierContentIDs() {
        let base = assistant(id: "msg_1", content: [.text("a"), tool(id: "tool_1")])
        let before = TranscriptPresentation.items(messages: [base])
        let grown = assistant(id: "msg_1", content: [.text("a"), tool(id: "tool_1"), .reasoning("r")])
        let after = TranscriptPresentation.items(messages: [grown])
        XCTAssertEqual(Array(after[0].contents.prefix(2).map(\.id)), before[0].contents.map(\.id))
        XCTAssertEqual(after[0].contents[2].id, .snapshotContent(messageID: "msg_1", index: 2))
    }
}
