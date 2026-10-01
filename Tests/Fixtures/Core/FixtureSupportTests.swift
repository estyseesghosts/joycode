import Foundation
import XCTest
@testable import Joycode

private struct SyntheticPayload: Codable, Sendable, Equatable {
    let status: String
}

private struct EmptyPayload: Decodable, Sendable {}

final class FixtureSupportTests: XCTestCase {
    func testSyntheticFixtureLoadsDeterministicallyAndIsNotLiveEvidence() throws {
        let data = try Data(contentsOf: try syntheticFixtureURL())
        let fixture: FixtureEnvelope<SyntheticPayload> = try FixtureLoader.load(
            data: data, operation: "server-info", release: "v2.0.20"
        )
        XCTAssertEqual(fixture.metadata.provenance, .synthetic)
        XCTAssertNil(fixture.metadata.captureID)
        XCTAssertEqual(fixture.payload.status, "synthetic-edge-case")
    }

    func testSyntheticAlgorithmCaseWithMatchingManifestDigestLoads() throws {
        let data = try syntheticAlgorithmCaseData()
        let manifest = syntheticAlgorithmManifest(for: data)
        let fixture: FixtureEnvelope<SyntheticPayload> = try FixtureLoader.load(
            data: data, operation: "server-info", release: "v2.0.20", manifest: manifest
        )
        XCTAssertEqual(fixture.metadata.provenance, .releasePinnedSanitizedCapture)
        XCTAssertEqual(fixture.metadata.captureID, "synthetic-algorithm-case")
    }

    func testSyntheticAlgorithmCaseWithMutatedFixtureFailsDigestComparison() throws {
        let data = try syntheticAlgorithmCaseData()
        let manifest = syntheticAlgorithmManifest(for: data)
        let mutated = Data(
            String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "synthetic-edge-case", with: "synthetic-mutated-case")
                .utf8
        )
        XCTAssertThrowsError(
            try FixtureLoader.load(
                data: mutated, operation: "server-info", release: "v2.0.20", manifest: manifest
            ) as FixtureEnvelope<SyntheticPayload>
        ) { error in
            guard case .contentDigestMismatch = error as? FixtureError else {
                return XCTFail("expected content digest comparison to reject mutated fixture")
            }
        }
    }

    func testSelfAssertedCaptureIsRejectedWithoutReviewedManifest() {
        let data = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.20","operation":"server-info","provenance":"release-pinned-sanitized-capture","sanitized":true,"captureID":"test-only-capture-reference"},"payload":{}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: data) as FixtureEnvelope<EmptyPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .unreviewedCapture("test-only-capture-reference"))
        }
    }

    func testFakeTestContentIsNotClassifiedAsReviewedCapture() {
        let data = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.20","operation":"server-info","provenance":"release-pinned-sanitized-capture","sanitized":true,"captureID":"fake-test-content"},"payload":{"status":"not-evidence"}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: data) as FixtureEnvelope<EmptyPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .unreviewedCapture("fake-test-content"))
        }
    }

    func testSHA256UsesExactFixtureBytes() {
        XCTAssertEqual(
            FixtureLoader.contentSHA256(for: Data("hello".utf8)),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testReviewedCaptureManifestContainsExactApprovedEntries() {
        XCTAssertEqual(FixtureCaptureManifest.reviewed, [
            FixtureCaptureManifest.Entry(captureID: "p0-v2.0.20-server-info-20261001", release: "v2.0.20", operation: "server-info", contentSHA256: "890db671f567e8e52b552b6f3969fdab2182f4af694741543456b651caf963a7"),
            FixtureCaptureManifest.Entry(captureID: "p0-v2.0.20-server-connected-20261001", release: "v2.0.20", operation: "event-server-connected", contentSHA256: "5f800722364e6f119d716f52d72c8e1542cec925d14a0fbbc2f32e61d6462d85")
        ])
    }

    func testReviewedServerInfoCaptureLoadsAndDecodesV2Payload() throws {
        let data = try Data(contentsOf: try fixtureURL(named: "server-info"))
        let fixture: FixtureEnvelope<ServerInfo> = try FixtureLoader.load(data: data, operation: "server-info")
        XCTAssertEqual(fixture.metadata.captureID, "p0-v2.0.20-server-info-20261001")
        XCTAssertEqual(fixture.payload.version, "2.0.20")
        XCTAssertEqual(fixture.payload.pid, 0)
        XCTAssertEqual(fixture.payload.urls, ["http://127.0.0.1"])
        XCTAssertEqual(fixture.payload.paths.tmp, "<SANDBOX_TMP>")
    }

    func testReviewedServerConnectedCaptureLoadsAndDecodesV2Event() throws {
        let data = try Data(contentsOf: try fixtureURL(named: "server-connected-event"))
        let fixture: FixtureEnvelope<EventEnvelope> = try FixtureLoader.load(data: data, operation: "event-server-connected")
        XCTAssertEqual(fixture.metadata.captureID, "p0-v2.0.20-server-connected-20261001")
        XCTAssertEqual(fixture.payload.id, "evt_<REDACTED_EVENT_ID>")
        XCTAssertEqual(fixture.payload.type, "server.connected")
        XCTAssertNil(fixture.payload.created)
        XCTAssertEqual(fixture.payload.data, .object([:]))
    }

    func testMalformedJSONAndIncompleteEnvelopeAreDistinct() {
        XCTAssertThrowsError(try FixtureLoader.load(data: Data("{".utf8)) as FixtureEnvelope<SyntheticPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .invalidJSON)
        }
        let incomplete = Data(#"{"metadata":{"schemaVersion":1}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: incomplete) as FixtureEnvelope<SyntheticPayload>) { error in
            guard case .invalidEnvelope = error as? FixtureError else { return XCTFail("expected invalid envelope") }
        }
    }

    func testEveryFixtureMustBeSanitizedAndCaptureIDMustBePathFree() {
        let unsanitized = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.20","operation":"server-info","provenance":"synthetic","sanitized":false},"payload":{"status":"x"}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: unsanitized) as FixtureEnvelope<SyntheticPayload>)
        let pathID = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.20","operation":"server-info","provenance":"release-pinned-sanitized-capture","sanitized":true,"captureID":"../private"},"payload":{"status":"x"}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: pathID) as FixtureEnvelope<SyntheticPayload>)
    }

    func testMissingFixtureFailsClearly() {
        let url = URL(fileURLWithPath: "/fixture-does-not-exist.json")
        XCTAssertThrowsError(try FixtureLoader.load(from: url) as FixtureEnvelope<SyntheticPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .missing(url))
        }
    }

    func testSchemaAndCompatibilityMismatchesFailClearly() {
        let data = Data(#"{"metadata":{"schemaVersion":99,"release":"v2.0.20","operation":"server-info","provenance":"synthetic","sanitized":true},"payload":{"status":"x"}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: data) as FixtureEnvelope<SyntheticPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .schemaMismatch(expected: 1, actual: 99))
        }
    }

    func testOperationMismatchFailsClearly() {
        let data = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.20","operation":"server-info","provenance":"synthetic","sanitized":true},"payload":{"status":"x"}}"#.utf8)
        XCTAssertThrowsError(
            try FixtureLoader.load(data: data, operation: "session-list") as FixtureEnvelope<SyntheticPayload>
        ) { error in
            XCTAssertEqual(
                error as? FixtureError,
                .incompatibleOperation(expected: "session-list", actual: "server-info")
            )
        }
    }

    func testPinnedReleaseMismatchFailsClearly() {
        let data = Data(#"{"metadata":{"schemaVersion":1,"release":"v2.0.19","operation":"server-info","provenance":"synthetic","sanitized":true},"payload":{"status":"x"}}"#.utf8)
        XCTAssertThrowsError(try FixtureLoader.load(data: data) as FixtureEnvelope<SyntheticPayload>) { error in
            XCTAssertEqual(error as? FixtureError, .incompatibleRelease(expected: "v2.0.20", actual: "v2.0.19"))
        }
    }

    private func syntheticFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "synthetic-server-info", withExtension: "json"))
    }

    private func fixtureURL(named name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
    }

    /// These are synthetic algorithm cases derived from the bundled synthetic
    /// fixture, not live OpenCode capture evidence.
    private func syntheticAlgorithmCaseData() throws -> Data {
        let data = try Data(contentsOf: try syntheticFixtureURL())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var metadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        metadata["provenance"] = FixtureProvenance.releasePinnedSanitizedCapture.rawValue
        metadata["captureID"] = "synthetic-algorithm-case"
        object["metadata"] = metadata
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func syntheticAlgorithmManifest(for data: Data) -> [FixtureCaptureManifest.Entry] {
        [FixtureCaptureManifest.Entry(
            captureID: "synthetic-algorithm-case",
            release: FixtureMetadata.pinnedRelease,
            operation: "server-info",
            contentSHA256: FixtureLoader.contentSHA256(for: data)
        )]
    }
}
