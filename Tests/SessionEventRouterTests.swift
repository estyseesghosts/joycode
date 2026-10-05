import Foundation
import XCTest
@testable import Joycode

// MARK: - Session event router tests (R08)
//
// The router is a pure classifier. Classification is source-verified against
// pinned OpenCode v2.0.20 (see docs/plan/r08-live-reconciliation-2026-10-05.md);
// these tests pin the table, the fallbacks, and the revert/delete shapes.

final class SessionEventRouterTests: XCTestCase {
    private let session = SessionID(rawValue: "ses-1")

    private func envelope(_ type: String, data: String) throws -> EventEnvelope {
        let json = "{\"id\":\"evt-1\",\"type\":\"\(type)\",\"created\":1,\"data\":\(data)}"
        return try JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8))
    }

    func testEveryKnownHistoryAffectingTypeInvalidatesItsSession() throws {
        for type in SessionEventRouter.knownHistoryAffectingTypes where type != "session.revert.committed" {
            let route = SessionEventRouter.route(try envelope(type, data: "{\"sessionID\":\"ses-1\"}"))
            XCTAssertEqual(route, .historyChanged(session), type)
        }
    }

    func testEveryKnownNoHistoryEffectTypeIsIgnoredWithOrWithoutSession() throws {
        for type in SessionEventRouter.knownNoHistoryEffectTypes {
            XCTAssertEqual(SessionEventRouter.route(try envelope(type, data: "{\"sessionID\":\"ses-1\"}")), .ignored, type)
            XCTAssertEqual(SessionEventRouter.route(try envelope(type, data: "{}")), .ignored, type)
        }
    }

    func testClassificationSetsDoNotOverlap() {
        XCTAssertTrue(SessionEventRouter.knownHistoryAffectingTypes.isDisjoint(with: SessionEventRouter.knownNoHistoryEffectTypes))
    }

    func testEphemeralDeltasAreNotAppliedAndDoNotInvalidate() throws {
        for type in ["session.text.delta", "session.reasoning.delta", "session.tool.input.delta", "session.tool.progress"] {
            XCTAssertEqual(SessionEventRouter.route(try envelope(type, data: "{\"sessionID\":\"ses-1\",\"delta\":\"x\"}")), .ignored, type)
        }
    }

    func testRevertCommittedCarriesBoundary() throws {
        let route = SessionEventRouter.route(try envelope("session.revert.committed", data: "{\"sessionID\":\"ses-1\",\"to\":\"msg-5\"}"))
        XCTAssertEqual(route, .messagesRemoved(session, boundary: "msg-5"))
    }

    func testRevertCommittedWithoutUsableBoundaryStillRemoves() throws {
        XCTAssertEqual(SessionEventRouter.route(try envelope("session.revert.committed", data: "{\"sessionID\":\"ses-1\"}")),
                       .messagesRemoved(session, boundary: nil))
        XCTAssertEqual(SessionEventRouter.route(try envelope("session.revert.committed", data: "{\"sessionID\":\"ses-1\",\"to\":\"\"}")),
                       .messagesRemoved(session, boundary: nil))
        XCTAssertEqual(SessionEventRouter.route(try envelope("session.revert.committed", data: "{\"sessionID\":\"ses-1\",\"to\":7}")),
                       .messagesRemoved(session, boundary: nil))
    }

    func testSessionDeleted() throws {
        XCTAssertEqual(SessionEventRouter.route(try envelope("session.deleted", data: "{\"sessionID\":\"ses-1\"}")), .sessionDeleted(session))
    }

    func testUnknownSessionFamilyWithSessionRefreshes() throws {
        XCTAssertEqual(SessionEventRouter.route(try envelope("session.future.thing", data: "{\"sessionID\":\"ses-1\"}")), .historyChanged(session))
    }

    func testSessionFamilyWithoutIdentifiableSessionIsUnroutable() throws {
        for data in ["{}", "{\"sessionID\":\"\"}", "{\"sessionID\":3}", "[]", "null", "\"text\""] {
            XCTAssertEqual(SessionEventRouter.route(try envelope("session.tool.success", data: data)), .unroutable, data)
            XCTAssertEqual(SessionEventRouter.route(try envelope("session.deleted", data: data)), .unroutable, data)
            XCTAssertEqual(SessionEventRouter.route(try envelope("session.future.thing", data: data)), .unroutable, data)
        }
    }

    func testNonSessionEventsAreIgnored() throws {
        for type in ["server.connected", "server.heartbeat", "project.updated", "sessions.something", "message.part.updated", "message.removed"] {
            XCTAssertEqual(SessionEventRouter.route(try envelope(type, data: "{\"sessionID\":\"ses-1\"}")), .ignored, type)
        }
    }

    func testLegacyMessageEventsAreNotInvented() {
        XCTAssertFalse(SessionEventRouter.knownHistoryAffectingTypes.contains("message.part.updated"))
        XCTAssertFalse(SessionEventRouter.knownHistoryAffectingTypes.contains("message.removed"))
    }
}
