import Foundation
import XCTest
@testable import Joycode

// MARK: - Rename adapter tests (SessionAPI)

final class SessionRenameAdapterTests: XCTestCase {
    private func connection() -> ServiceConnection { ServiceConnection(connectionID: ConnectionID(rawValue: "rename-test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!), credentialCapability: RenameCredentials()) }
    private func info(_ title: String = "server") -> SessionInfo { SessionInfo(id: "ses-rename", parentID: nil, projectID: "p", title: title, location: LocationRef(directory: "/work")) }
    private func encodeInfo(_ info: SessionInfo) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "data": [
                "id": info.id,
                "parentID": info.parentID as Any,
                "projectID": info.projectID,
                "title": info.title as Any,
                "location": ["directory": info.location.directory]
            ]
        ])
    }

    // 18. testRenameRequestUsesPatchAndNoQuery
    func testRenameRequestUsesPatchAndNoQuery() throws {
        let request = SessionAPI.updateTitleRequest(sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.relativePath, "/api/session/ses-rename")
        XCTAssertTrue(request.queryItems.isEmpty)
    }

    // 19. testRenameRequestBodyContainsOnlyTitle
    func testRenameRequestBodyContainsOnlyTitle() throws {
        let body = try XCTUnwrap(SessionAPI.updateTitleRequest(sessionID: SessionID(rawValue: "s"), title: "New").body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json["title"] as? String, "New")
    }

    // 20. testRenameAppliedPerformsSameConnectionReadback
    func testRenameAppliedPerformsSameConnectionReadback() async throws {
        let infoData = encodeInfo(info())
        let transport = RenameTestTransport(responses: [
            (204, Data()),
            (200, infoData)
        ])
        let api = SessionAPI(transport: transport)
        let conn = connection()
        let result = try await api.rename(connection: conn, sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        let requests = await transport.requests
        let connections = await transport.connections
        XCTAssertEqual(requests.count, 2)
        // First: PATCH to /api/session/ses-rename
        XCTAssertEqual(requests[0].method, .patch)
        XCTAssertEqual(requests[0].relativePath, "/api/session/ses-rename")
        // Second: GET to /api/session/ses-rename (same connection)
        XCTAssertEqual(requests[1].method, .get)
        XCTAssertEqual(requests[1].relativePath, "/api/session/ses-rename")
        // Both requests must use the same connection (same resolved service context)
        XCTAssertEqual(connections.count, 2)
        XCTAssertEqual(connections[0].connectionID.rawValue, connections[1].connectionID.rawValue, "PATCH and GET readback must share the same connection")
        if case .applied(let authoritative) = result {
            XCTAssertEqual(authoritative?.id, "ses-rename")
        } else { XCTFail("Expected .applied, got \(result)") }
    }

    // 21. testRenameDeclaredRejectionPerformsReadback
    func testRenameDeclaredRejectionPerformsReadback() async throws {
        let infoData = encodeInfo(info("server title"))
        let transport = RenameTestTransport(responses: [
            (400, Data()),
            (200, infoData)
        ])
        let api = SessionAPI(transport: transport)
        let result = try await api.rename(connection: connection(), sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        if case .rejected(let error, let authoritative) = result {
            XCTAssertEqual(error, .backend(statusCode: 400))
            XCTAssertEqual(authoritative?.title, "server title")
        } else { XCTFail("Expected .rejected, got \(result)") }
    }

    // 22. testRenameUndeclared500IsUnknown
    func testRenameUndeclared500IsUnknown() async throws {
        let infoData = encodeInfo(info())
        let transport = RenameTestTransport(responses: [
            (500, Data()),
            (200, infoData)
        ])
        let api = SessionAPI(transport: transport)
        let result = try await api.rename(connection: connection(), sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        if case .unknown(let error, let authoritative) = result {
            XCTAssertEqual(error, .backend(statusCode: 500))
            XCTAssertNotNil(authoritative)
        } else { XCTFail("Expected .unknown, got \(result)") }
    }

    // 23. testRenameLostReplyIsUnknownWithReadback
    func testRenameLostReplyIsUnknownWithReadback() async throws {
        let infoData = encodeInfo(info("readback"))
        let transport = RenameTestTransport(responses: [
            (200, Data()),
            (200, infoData)
        ])
        let api = SessionAPI(transport: transport)
        let result = try await api.rename(connection: connection(), sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "Should perform readback after non-204 success")
        if case .unknown(let error, let authoritative) = result {
            XCTAssertEqual(error, .requestFailed)
            XCTAssertEqual(authoritative?.title, "readback")
        } else { XCTFail("Expected .unknown, got \(result)") }
    }

    // 24. testRenameReadbackFailureYieldsNilAuthoritative
    func testRenameReadbackFailureYieldsNilAuthoritative() async throws {
        let transport = RenameTestTransport(responses: [
            (401, Data()),
            (500, Data())
        ])
        let api = SessionAPI(transport: transport)
        let result = try await api.rename(connection: connection(), sessionID: SessionID(rawValue: "ses-rename"), title: "New")
        if case .rejected(let error, let authoritative) = result {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertNil(authoritative, "Readback failure should yield nil authoritative")
        } else { XCTFail("Expected .rejected, got \(result)") }
    }

    // 25. testDeclaredRenameRejectionClassification
    func testDeclaredRenameRejectionClassification() {
        XCTAssertTrue(SessionAPI.isDeclaredRenameRejection(.backend(statusCode: 400)))
        XCTAssertTrue(SessionAPI.isDeclaredRenameRejection(.unauthorized))
        XCTAssertTrue(SessionAPI.isDeclaredRenameRejection(.notFound))
        XCTAssertFalse(SessionAPI.isDeclaredRenameRejection(.backend(statusCode: 500)))
        XCTAssertFalse(SessionAPI.isDeclaredRenameRejection(.backend(statusCode: 502)))
        XCTAssertFalse(SessionAPI.isDeclaredRenameRejection(.requestFailed))
        XCTAssertFalse(SessionAPI.isDeclaredRenameRejection(.malformedResponse))
        XCTAssertFalse(SessionAPI.isDeclaredRenameRejection(.notConnected))
    }
}

// MARK: - Store rename tests

final class SessionRenameStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor private func preferences() -> LocalPreferencesStore {
        LocalPreferencesStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-Rename-\(UUID().uuidString)"))
    }

    private func info(_ id: String = "ses-1", title: String? = "Real", parent: String? = nil, directory: String = "/work") -> SessionInfo {
        SessionInfo(id: id, parentID: parent, projectID: "project", title: title, location: LocationRef(directory: directory))
    }

    private func summary(_ id: String = "ses-1", title: String? = "Real", parent: String? = nil, directory: String = "/work") -> SessionSummary {
        SessionSummary(info: info(id, title: title, parent: parent, directory: directory))
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func connection() -> ServiceConnection {
        ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!), credentialCapability: TestCredentials())
    }

    // 1. testRenameTrimsAndSendsNonblankTitle
    @MainActor func testRenameTrimsAndSendsNonblankTitle() async {
        let recorder = RenameRecorder()
        let loaded = summary("ses-1", title: "Original")
        let applied = summary("ses-1", title: "New Title")
        let store = makeStore(get: { _ in loaded }, rename: { id, title in await recorder.record(id, title); return .applied(authoritative: self.summary(id.rawValue, title: title)) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("  New Title  ")
        let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle)
        let entry = await recorder.first()
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.0, loaded.id)
        XCTAssertEqual(entry?.1, "New Title")
        XCTAssertEqual(store.activeSession?.title, "New Title")
    }

    // 2. testRenameRejectsBlankAndUnchangedTitleWithoutCalling
    @MainActor func testRenameRejectsBlankAndUnchangedTitleWithoutCalling() async {
        let recorder = RenameRecorder()
        let loaded = summary("ses-1", title: "Same")
        let store = makeStore(get: { _ in loaded }, rename: { id, title in await recorder.record(id, title); return .applied(authoritative: loaded) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("   \n  "); store.rename("Same")
        let count = await recorder.count()
        XCTAssertEqual(count, 0, "Blank or unchanged rename should not call the rename closure")
        XCTAssertEqual(store.renameState, .idle)
    }

    // 3. testDuplicateRenameWhileInFlightIsIgnored
    @MainActor func testDuplicateRenameWhileInFlightIsIgnored() async {
        let gate = RenameGate()
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(get: { _ in loaded }, rename: { id, title in await gate.enter(); return .applied(authoritative: self.summary(id.rawValue, title: title)) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("First"); await gate.waitUntilEntered()
        store.rename("Second")
        if case .inProgress(let req) = store.renameState { XCTAssertEqual(req.title, "First") }
        else { XCTFail("Expected inProgress with First title") }
        let count = await gate.callCount()
        XCTAssertEqual(count, 1)
        await gate.release()
    }

    // 4. testDeclaredRejectionPerformsReadbackAndRemainsRetryable
    @MainActor func testDeclaredRejectionPerformsReadbackAndRemainsRetryable() async {
        let loaded = summary("ses-1", title: "Original")
        let callCounter = SendableCounter()
        let store = makeStore(get: { _ in loaded }, rename: { id, title in
            let count = await callCounter.increment()
            if count == 1 {
                return .rejected(SessionProblem.notFound, authoritative: loaded)
            }
            return .applied(authoritative: SessionSummary(info: SessionInfo(id: id.rawValue, parentID: nil, projectID: "project", title: title, location: LocationRef(directory: "/work"))))
        })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)

        // First rename: returns .rejected
        store.rename("New")
        let rejected = await waitUntil {
            if case .rejected = store.renameState { return true }; return false
        }; XCTAssertTrue(rejected)
        if case .rejected(let req, let problem, let serverTitle) = store.renameState {
            XCTAssertEqual(req.title, "New")
            XCTAssertEqual(problem, SessionProblem.notFound)
            XCTAssertEqual(serverTitle, "Original")
        } else { XCTFail("Expected rejected state") }

        // Retry from rejected state: second rename call returns .applied
        store.rename("New")
        let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle, "Retry from rejected should succeed")
        XCTAssertEqual(store.activeSession?.title, "New")
    }

    // 5. testUndeclaredBackendErrorIsUnknownNotRejected
    @MainActor func testUndeclaredBackendErrorIsUnknownNotRejected() async {
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in .unknown(SessionProblem.backend(500), authoritative: loaded) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown)
        if case .unknown(let req, let serverTitle) = store.renameState {
            XCTAssertEqual(req.title, "New")
            XCTAssertEqual(serverTitle, "Original")
        } else { XCTFail("Expected unknown state") }
        // Ensure it's not rejected
        if case .rejected = store.renameState { XCTFail("Undeclared 500 should be unknown, not rejected") }
    }

    // 6. testLostReplyWithDifferingReadbackStaysQualifiedUnknown
    @MainActor func testLostReplyWithDifferingReadbackStaysQualifiedUnknown() async {
        let differing = summary("ses-1", title: "Server Changed It")
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in .unknown(SessionProblem.requestFailed, authoritative: differing) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown)
        if case .unknown(let req, let serverTitle) = store.renameState {
            XCTAssertEqual(req.title, "New")
            XCTAssertEqual(serverTitle, "Server Changed It")
        } else { XCTFail("Expected unknown with differing server title") }
    }

    // 7. testLostReplyWithMatchingReadbackClears
    @MainActor func testLostReplyWithMatchingReadbackClears() async {
        let matching = summary("ses-1", title: "New")
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in .unknown(SessionProblem.requestFailed, authoritative: matching) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle, "Matching authoritative title should clear to idle")
    }

    // 8. testCheckRenameMatchingTitleClears
    @MainActor func testCheckRenameMatchingTitleClears() async {
        let loaded = summary("ses-1", title: "Original")
        let fetched = summary("ses-1", title: "New")
        let getCount = SendableCounter()
        let store = makeStore(get: { _ in
            let count = await getCount.increment()
            if count <= 1 { return loaded }
            return fetched
        }, rename: { _, _ in SessionRenameOutcome.unknown(SessionProblem.requestFailed, authoritative: nil) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown)
        store.checkRename()
        let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle, "Matching title after check should clear to idle")
    }

    // 9. testCheckRenameDifferingTitleStaysQualified
    @MainActor func testCheckRenameDifferingTitleStaysQualified() async {
        let loaded = summary("ses-1", title: "Original")
        let fetched = summary("ses-1", title: "Server Kept This")
        let getCount = SendableCounter()
        let store = makeStore(get: { _ in
            let count = await getCount.increment()
            if count <= 1 { return loaded }
            return fetched
        }, rename: { _, _ in SessionRenameOutcome.unknown(SessionProblem.requestFailed, authoritative: nil) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown)
        store.checkRename()
        let stillUnknown = await waitUntil { if case .unknown(let req, let serverTitle) = store.renameState { return req.title == "New" && serverTitle == "Server Kept This" }; return false }; XCTAssertTrue(stillUnknown)
    }

    // 10. testLoadDuringInFlightRenameIsExcluded
    @MainActor func testLoadDuringInFlightRenameIsExcluded() async {
        let gate = RenameGate()
        let loaded = summary("ses-1", title: "Original")
        let getRecorder = GetRecorder()
        let store = makeStore(get: { id in await getRecorder.record(id); return loaded }, rename: { _, _ in await gate.enter(); return .applied(authoritative: loaded) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New"); await gate.waitUntilEntered()
        // Attempt to load a different session while rename is in flight — must be excluded
        store.load(SessionID(rawValue: "ses-other"))
        let getCount = await getRecorder.callCount()
        XCTAssertEqual(getCount, 1, "get should be called exactly once (the initial load)")
        let recordedIDs = await getRecorder.recordedIDs
        XCTAssertEqual(recordedIDs, [SessionID(rawValue: "ses-1")], "Only the initial load ID should have been recorded")
        XCTAssertEqual(store.state, .loaded(loaded), "State must stay loaded")
        if case .inProgress = store.renameState { } else { XCTFail("renameState must stay inProgress") }
        await gate.releaseAndWait()
    }

    // 11. testCreateDuringInFlightRenameIsExcluded
    @MainActor func testCreateDuringInFlightRenameIsExcluded() async {
        let gate = RenameGate()
        let recorder = CreateRecorder()
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), get: { _ in loaded }, create: { request in await recorder.record(request); return self.summary(request.id.rawValue) }, rename: { _, _ in await gate.enter(); return .applied(authoritative: loaded) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New"); await gate.waitUntilEntered()
        store.create()
        let count = await recorder.count()
        XCTAssertEqual(count, 0, "Create should be excluded while rename is in flight")
        await gate.release()
    }

    // 12. testLateRenameCompletionAfterClearDoesNotPublish
    @MainActor func testLateRenameCompletionAfterClearDoesNotPublish() async {
        let gate = RenameGate()
        let loaded = summary("ses-1", title: "Original")
        let renamed = summary("ses-1", title: "Renamed")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in await gate.enter(); return .applied(authoritative: renamed) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("Renamed"); await gate.waitUntilEntered()
        store.clear()
        XCTAssertEqual(store.state, .empty)
        XCTAssertEqual(store.renameState, .idle)
        // Release the gate and wait for the rename closure to return deterministically
        await gate.releaseAndWait()
        // Drain the main-actor scheduler a bounded number of times
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.state, .empty, "Late rename completion after clear must not publish")
        XCTAssertEqual(store.renameState, .idle)
    }

    // 13. testRenameCancellationIsUnknownPreservingDraft
    @MainActor func testRenameCancellationIsUnknownPreservingDraft() async {
        let loaded = summary("ses-1", title: "Original")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in
            throw CancellationError() as Error
        })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown, "Cancellation after dispatch is sent with unknown outcome, preserving the draft")
        if case .unknown(let request, let serverTitle) = store.renameState {
            XCTAssertEqual(request.title, "New")
            XCTAssertNil(serverTitle)
        } else { XCTFail("Expected unknown rename state") }
        XCTAssertEqual(store.activeSession?.title, "Original")
        XCTAssertFalse({ if case .inProgress = store.renameState { return true }; return false }())
    }

    // 14. testRefreshRootsDoesNotRegressConfirmedRenameTitle
    @MainActor func testRefreshRootsDoesNotRegressConfirmedRenameTitle() async {
        let listGate = ListGate()
        let loaded = summary("ses-1", title: "Old Title")
        let staleRoots = [summary("ses-1", title: "Old Title"), summary("ses-2", title: "Other")]
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in
            await listGate.enter()
            return SessionPage(sessions: staleRoots, nextCursor: nil, previousCursor: nil)
        }, get: { _ in loaded }, rename: { id, title in
            return SessionRenameOutcome.applied(authoritative: self.summary(id.rawValue, title: title))
        })
        store.load(loaded.id); let ldone = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(ldone)

        // Start refresh — list is gated so it starts but does not complete
        store.refreshRoots()
        await listGate.waitUntilEntered()

        // Rename completes while list is in flight — bumps generation, cancels operation
        store.rename("Confirmed New")
        let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle)
        XCTAssertEqual(store.activeSession?.title, "Confirmed New")

        // Release the stale list. The refresh operation was cancelled by rename()
        // (generation guard will fail). Title must not regress.
        await listGate.release()
        // Drain the main-actor scheduler to let the cancelled operation settle.
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.activeSession?.title, "Confirmed New", "Stale refresh must not regress a confirmed rename title")
        XCTAssertEqual(store.roots.count, 0, "Refresh should not have applied stale roots after rename cancelled it")
    }

    // 15. testRefreshRootsAdoptsNewerServerTitleForActiveSession
    @MainActor func testRefreshRootsAdoptsNewerServerTitleForActiveSession() async {
        let loaded = summary("ses-1", title: "Loaded Title")
        let newer = summary("ses-1", title: "Server Updated")
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in SessionPage(sessions: [newer, self.summary("ses-2", title: "Other")], nextCursor: nil, previousCursor: nil) }, get: { _ in loaded })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.refreshRoots()
        let updated = await waitUntil { store.activeSession?.title == "Server Updated" }; XCTAssertTrue(updated, "Refresh should adopt newer server title for active session")
    }

    // 15b. testFreshRefreshAfterRenameAdoptsNewerServerTitle
    @MainActor func testFreshRefreshAfterRenameAdoptsNewerServerTitle() async {
        let getCount = SendableCounter()
        let loaded = summary("ses-1", title: "Old Title")
        let newer = summary("ses-1", title: "Server Updated")
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in SessionPage(sessions: [newer, self.summary("ses-2", title: "Other")], nextCursor: nil, previousCursor: nil) }, get: { _ in
            let count = await getCount.increment()
            if count <= 1 { return loaded }
            return self.summary("ses-1", title: "New")
        }, rename: { id, title in
            return .applied(authoritative: self.summary(id.rawValue, title: title))
        })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        // Rename completes
        store.rename("New")
        let renamed = await waitUntil { store.renameState == .idle }; XCTAssertTrue(renamed)
        XCTAssertEqual(store.activeSession?.title, "New")
        // Fresh refresh after rename should adopt the newer server title
        store.refreshRoots()
        let updated = await waitUntil { store.activeSession?.title == "Server Updated" }; XCTAssertTrue(updated, "Fresh refresh after rename must adopt newer server title")
    }

    // 16. testRenamePreservesPersistedSelection
    @MainActor func testRenamePreservesPersistedSelection() async throws {
        let prefs = preferences()
        let loaded = summary("ses-1", title: "Original")
        let renamed = summary("ses-1", title: "New")
        let store = makeStore(preferences: prefs, get: { _ in loaded }, rename: { _, _ in .applied(authoritative: renamed) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        store.rename("New"); let idle = await waitUntil { store.renameState == .idle }; XCTAssertTrue(idle)
        XCTAssertEqual(try prefs.load().lastSessionID?.rawValue, "ses-1", "Persisted selection should survive rename")
    }

    // 17. testRestoreLoadsAuthoritativeTitleAfterRename
    @MainActor func testRestoreLoadsAuthoritativeTitleAfterRename() async throws {
        let prefs = preferences()
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let authoritative = summary("ses-1", title: "Server Authoritative")
        let store = makeStore(preferences: prefs, get: { _ in authoritative })
        store.restore()
        let loaded = await waitUntil { store.state == .loaded(authoritative) }; XCTAssertTrue(loaded)
        XCTAssertEqual(store.activeSession?.title, "Server Authoritative")
    }

    // 17b. testRenameAppliedWithWrongIDStaysUnknown
    @MainActor func testRenameAppliedWithWrongIDStaysUnknown() async {
        let loaded = summary("ses-1", title: "Original")
        let wrong = summary("ses-wrong", title: "New")
        let store = makeStore(get: { _ in loaded }, rename: { _, _ in .applied(authoritative: wrong) })
        store.load(loaded.id); let done = await waitUntil { store.state == .loaded(loaded) }; XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }; XCTAssertTrue(unknown, "Wrong-ID authoritative must not clear uncertainty")
        if case .unknown(let request, let serverTitle) = store.renameState {
            XCTAssertEqual(request.title, "New")
            XCTAssertNil(serverTitle)
        } else { XCTFail("Expected unknown rename state") }
        XCTAssertEqual(store.activeSession?.id.rawValue, "ses-1")
        XCTAssertEqual(store.activeSession?.title, "Original")
    }

    // MARK: - Helpers

    @MainActor private func makeStore(
        preferences: LocalPreferencesStore? = nil,
        location: ActiveLocationProviding = FakeLocationProvider(),
        list: @escaping @Sendable (SessionListQuery) async throws -> SessionPage = { _ in SessionPage(sessions: [], nextCursor: nil, previousCursor: nil) },
        get: @escaping @Sendable (SessionID) async throws -> SessionSummary = { _ in SessionSummary(info: SessionInfo(id: "ses-1", parentID: nil, projectID: "p", title: "T", location: LocationRef(directory: "/work"))) },
        create: @escaping @Sendable (SessionCreateRequest) async throws -> SessionSummary = { _ in throw SessionAPIError.requestFailed },
        rename: @escaping @Sendable (SessionID, String) async throws -> SessionRenameOutcome = { _, _ in .rejected(SessionProblem.notConnected, authoritative: nil) }
    ) -> ActiveSessionStore {
        ActiveSessionStore(preferences: preferences ?? self.preferences(), location: location, list: list, get: get, create: create, rename: rename)
    }
}

// MARK: - Shared test helpers

@MainActor private final class FakeLocationProvider: ActiveLocationProviding {
    var activeLocation: ResolvedLocation?
    init(active: URL? = nil) { if let active { activeLocation = ResolvedLocation(directory: active, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: active, canonical: active)) } }
}

private struct RenameCredentials: CredentialCapability { var safeDescription: String { "rename-test" }; func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil } }

private struct TestCredentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

// Transport that records requests, connections, and returns queued responses in order
private actor RenameTestTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private(set) var connections: [ServiceConnection] = []
    private var responses: [(Int, Data)]
    init(responses: [(Int, Data)]) { self.responses = responses }
    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        connections.append(connection)
        guard !responses.isEmpty else { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let (status, body) = responses.removeFirst()
        return HTTPResponse(statusCode: status, headers: [:], body: body)
    }
}

// Continuation-based gate for rename operations
private actor RenameGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private(set) var count: Int = 0
    func enter() async {
        count += 1
        entered = true
        await withCheckedContinuation { continuation = $0 }
        entered = false
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func releaseAndWait() async {
        release()
        // Wait until the continuation body in enter() has fully returned.
        // entered is set to false only after withCheckedContinuation returns.
        while entered { await Task.yield() }
    }
    func callCount() -> Int { count }
}

private actor RenameRecorder {
    private var entries: [(SessionID, String)] = []
    func record(_ id: SessionID, _ title: String) { entries.append((id, title)) }
    func count() -> Int { entries.count }
    func first() -> (SessionID, String)? { entries.first }
}

private actor CreateRecorder {
    private(set) var recordedRequests: [SessionCreateRequest] = []
    func count() -> Int { recordedRequests.count }
    func firstRequest() -> SessionCreateRequest? { recordedRequests.first }
    func record(_ request: SessionCreateRequest) { recordedRequests.append(request) }
}

private actor CreateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var requests = 0
    func enter(_ request: SessionCreateRequest) async { requests += 1; entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func count() -> Int { requests }
    func release() { continuation?.resume(); continuation = nil }
}

private actor LoadGate {
    private var continuation: CheckedContinuation<SessionSummary, Never>?
    private var entered = false
    func wait() async -> SessionSummary { await withCheckedContinuation { continuation = $0; entered = true } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release(_ summary: SessionSummary) { continuation?.resume(returning: summary); continuation = nil }
}

private actor SendableCounter {
    private var value: Int = 0
    func increment() -> Int { value += 1; return value }
}

// Records get calls for asserting exclusion
private actor GetRecorder {
    private(set) var recordedIDs: [SessionID] = []
    func record(_ id: SessionID) { recordedIDs.append(id) }
    func callCount() -> Int { recordedIDs.count }
}

// Continuation-based gate for list operations
private actor ListGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func enter() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil; entered = false }
}