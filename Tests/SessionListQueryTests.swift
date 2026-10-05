import Foundation
import XCTest
@testable import Joycode

/// H05a: session list `directory` filter uses the ordinary `directory` query
/// item (URL.path), not `location[directory]`. Roots/cursor behavior unchanged.
final class SessionListQueryTests: XCTestCase {
    private func endpoint() -> ServiceEndpoint {
        ServiceEndpoint(baseURL: URL(string: "http://localhost")!)
    }

    func testRootsPlusDirectoryEncodesOrdinaryDirectoryItem() {
        let query = SessionListQuery(
            parent: .roots,
            directory: URL(fileURLWithPath: "/work")
        )
        XCTAssertEqual(
            SessionAPI.listRequest(query: query).queryItems,
            [.init(name: "parentID", value: "null"), .init(name: "directory", value: "/work")]
        )
    }

    func testDirectoryUsesBareNameNotLocationSubscript() {
        let query = SessionListQuery(directory: URL(fileURLWithPath: "/work"))
        let items = SessionAPI.listRequest(query: query).queryItems
        XCTAssertEqual(items, [.init(name: "directory", value: "/work")])
        XCTAssertFalse(items.contains(where: { $0.name == "location[directory]" }))
    }

    func testNilDirectoryOmitsDirectoryItem() {
        XCTAssertTrue(SessionAPI.listRequest(query: .init()).queryItems.isEmpty)
        let items = SessionAPI.listRequest(
            query: .init(parent: .roots, limit: 4, order: .asc, cursor: "cursor")
        ).queryItems
        XCTAssertEqual(
            items,
            [
                .init(name: "parentID", value: "null"),
                .init(name: "limit", value: "4"),
                .init(name: "order", value: "asc"),
                .init(name: "cursor", value: "cursor")
            ]
        )
        XCTAssertFalse(items.contains(where: { $0.name == "directory" }))
    }

    func testSpaceAndUnicodePathRoundTripsThroughURLComposition() throws {
        let directory = URL(fileURLWithPath: "/work/tree with spaces ✓")
        let url = try HTTPRequestBuilder.makeURL(
            endpoint: endpoint(),
            request: SessionAPI.listRequest(query: .init(parent: .roots, directory: directory))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "directory" })?.value,
            directory.path
        )
        XCTAssertTrue(url.absoluteString.contains("%20"))
        XCTAssertFalse(url.absoluteString.contains("location%5Bdirectory%5D") || url.absoluteString.contains("location[directory]"))
    }

    func testOpaqueCursorPreservesDirectoryScope() {
        let query = SessionListQuery(
            parent: .roots,
            directory: URL(fileURLWithPath: "/work"),
            cursor: "opaque+cursor/with=special&chars"
        )
        XCTAssertEqual(
            SessionAPI.listRequest(query: query).queryItems,
            [
                .init(name: "parentID", value: "null"),
                .init(name: "directory", value: "/work"),
                .init(name: "cursor", value: "opaque+cursor/with=special&chars")
            ]
        )
    }

    func testOpaqueCursorRoundTripsVerbatimThroughURLComposition() throws {
        let directory = URL(fileURLWithPath: "/work")
        let cursor = "opaque+cursor/with=special&chars"
        let url = try HTTPRequestBuilder.makeURL(
            endpoint: endpoint(),
            request: SessionAPI.listRequest(query: .init(parent: .roots, directory: directory, cursor: cursor))
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "directory" })?.value, "/work")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, cursor)
    }
}
