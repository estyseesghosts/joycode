import Foundation
import XCTest
@testable import Joycode

final class SessionStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor private func preferences() -> LocalPreferencesStore {
        LocalPreferencesStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-Sessions-\(UUID().uuidString)"))
    }

    private func info(_ id: String = "ses-1", title: String? = "Real", parent: String? = nil, directory: String = "/work") -> SessionInfo {
        SessionInfo(id: id, parentID: parent, projectID: "project", title: title, location: LocationRef(directory: directory))
    }

    private func summary(_ id: String = "ses-1", title: String? = "Real", parent: String? = nil, directory: String = "/work") -> SessionSummary {
        SessionSummary(info: info(id, title: title, parent: parent, directory: directory))
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func connection() -> ServiceConnection {
        ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!), credentialCapability: TestCredentials())
    }

    func testListRequestRootsParentAndCursorShapes() throws {
        let id = SessionID(rawValue: "ses-1")
        XCTAssertEqual(SessionAPI.listRequest(query: .init(parent: .roots)).queryItems, [.init(name: "parentID", value: "null")])
        XCTAssertEqual(SessionAPI.listRequest(query: .init(parent: .parent(id))).queryItems, [.init(name: "parentID", value: "ses-1")])
        XCTAssertEqual(SessionAPI.listRequest(query: .init(parent: .parent(id), limit: 0, order: .desc, cursor: "next")).queryItems, [.init(name: "parentID", value: "ses-1"), .init(name: "order", value: "desc"), .init(name: "cursor", value: "next")])
        XCTAssertEqual(SessionAPI.listRequest(query: .init(parent: .any, limit: 4, order: .asc, cursor: "cursor")).queryItems, [.init(name: "limit", value: "4"), .init(name: "order", value: "asc"), .init(name: "cursor", value: "cursor")])
        XCTAssertTrue(SessionAPI.listRequest(query: .init()).queryItems.isEmpty)
    }

    func testGetAndHistoryRequestPaths() throws {
        let id = SessionID(rawValue: "ses-1")
        let get = SessionAPI.getRequest(sessionID: id)
        XCTAssertEqual(get.method, .get); XCTAssertEqual(get.relativePath, "/api/session/ses-1")
        XCTAssertEqual(SessionAPI.historyRequest(sessionID: id).method, .get)
        XCTAssertEqual(SessionAPI.historyRequest(sessionID: id).relativePath, "/api/session/ses-1/message")
        XCTAssertEqual(SessionAPI.historyRequest(sessionID: id, limit: 4, cursor: "c").queryItems, [.init(name: "limit", value: "4"), .init(name: "cursor", value: "c")])
        XCTAssertEqual(SessionAPI.historyRequest(sessionID: id, limit: 0, cursor: nil).queryItems, [])
    }

    func testCreateRequestBodyCarriesIDTitleAndLocation() throws {
        let id = SessionID(rawValue: "ses-1")
        let body = try XCTUnwrap(SessionAPI.createRequest(.init(id: id, title: "T", location: URL(fileURLWithPath: "/approved"))).body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "ses-1")
        XCTAssertEqual((json["location"] as? [String: String])?["directory"], "/approved")
        XCTAssertEqual(json["title"] as? String, "T")
        let noTitle = try XCTUnwrap(SessionAPI.createRequest(.init(id: id, title: nil, location: URL(fileURLWithPath: "/approved"))).body)
        XCTAssertNil((try JSONSerialization.jsonObject(with: noTitle) as? [String: Any])?["title"])
    }

    func testSessionAPIMapsStatusAndMalformedErrors() async throws {
        let id = SessionID(rawValue: "ses-1")
        let malformed = CapturingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("bad".utf8)))
        do { _ = try await SessionAPI(transport: malformed).get(connection: connection(), sessionID: id); XCTFail() } catch let error as SessionAPIError { XCTAssertEqual(error, .malformedResponse) }
        for (transportError, expected) in [(HTTPTransportError.backend(statusCode: 404), SessionAPIError.notFound), (.unauthorized, .unauthorized), (.backend(statusCode: 500), .backend(statusCode: 500)), (.transport("x"), .requestFailed)] {
            let transport = CapturingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()), error: transportError)
            do { _ = try await SessionAPI(transport: transport).list(connection: connection(), query: .init()); XCTFail() } catch let error as SessionAPIError { XCTAssertEqual(error, expected) }
        }
    }

    func testSessionSummaryTitleFallbackRootAndDirectory() {
        XCTAssertEqual(summary(title: nil).title, "Untitled Session")
        XCTAssertEqual(summary(title: "").title, "Untitled Session")
        XCTAssertTrue(summary(parent: nil).isRoot); XCTAssertFalse(summary(parent: "parent").isRoot)
        XCTAssertEqual(summary(directory: "/approved").directory.path, "/approved")
    }

    func testSessionInfoDecodesFullWireFixtureAndMapsRootSummary() throws {
        let data = Data(#"{"id":"ses-full","projectID":"project","title":"Full","location":{"directory":"/work"},"parentID":null,"cost":12,"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}},"time":{"created":1,"updated":2}}"#.utf8)
        XCTAssertTrue(SessionSummary(info: try SessionInfo.decode(data)).isRoot)
        let child = Data(#"{"id":"ses-child","projectID":"project","title":"Child","location":{"directory":"/work"},"parentID":"ses-full","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1,"updated":2}}"#.utf8)
        XCTAssertFalse(SessionSummary(info: try SessionInfo.decode(child)).isRoot)
    }

    @MainActor func testRefreshRootsHoldsMultipleRootsWithoutActiveSelection() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in SessionPage(sessions: [self.summary("ses-1"), self.summary("ses-2")], nextCursor: nil, previousCursor: nil) })
        store.refreshRoots(); let done = await waitUntil { store.roots.count == 2 }; XCTAssertTrue(done); XCTAssertEqual(store.roots.count, 2); XCTAssertNil(store.activeSession)
    }

    @MainActor func testRefreshRootsErrorDoesNotClobberLoadedSession() async {
        let expected = summary(); let signal = ListStartedSignal(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in await signal.mark(); throw SessionAPIError.requestFailed }, get: { _ in expected })
        store.load(expected.id); let loaded = await waitUntil { store.state == .loaded(expected) }; XCTAssertTrue(loaded); store.refreshRoots(); await signal.wait(); for _ in 0..<20 { await Task.yield() }; XCTAssertEqual(store.state, .loaded(expected))
    }

    @MainActor func testLoadSuccessPersistsIDAndPreservesSelectedDirectory() async throws {
        let prefs = preferences(); try prefs.save(LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/chosen")))
        let store = makeStore(preferences: prefs, get: { _ in self.summary(title: "Loaded", directory: "/actual") })
        store.load(SessionID(rawValue: "ses-1")); let loaded = await waitUntil { if case .loaded = store.state { return true }; return false }; XCTAssertTrue(loaded)
        XCTAssertEqual(try prefs.load().lastSessionID?.rawValue, "ses-1"); XCTAssertEqual(try prefs.load().selectedDirectory?.path, "/chosen")
    }

    @MainActor func testRestoreWithPersistedIDLoadsTrueTitleAndLocation() async throws {
        let prefs = preferences(); try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let expected = summary(title: "Server title", directory: "/server"); let store = makeStore(preferences: prefs, get: { _ in expected }); store.restore()
        let loaded = await waitUntil { store.state == .loaded(expected) }; XCTAssertTrue(loaded)
    }

    @MainActor func testRestoreNotFoundClearsSelectionAndIsEmpty() async throws {
        let prefs = preferences(); try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "gone")))
        let store = makeStore(preferences: prefs, get: { _ in throw SessionAPIError.notFound }); store.restore(); let empty = await waitUntil { store.state == .empty }; XCTAssertTrue(empty); XCTAssertNil(try prefs.load().lastSessionID)
    }

    @MainActor func testRestoreWithoutPersistedIDIsEmpty() { let store = makeStore(); store.restore(); XCTAssertEqual(store.state, .empty) }

    @MainActor func testCreateSuccessPersistsGeneratedIDAndUsesApprovedLocation() async throws {
        let prefs = preferences(); let recorder = CreateRecorder(); let store = makeStore(preferences: prefs, location: FakeLocationProvider(active: URL(fileURLWithPath: "/approved")), create: { request in await recorder.record(request); return self.summary(request.id.rawValue, directory: request.location.path) })
        store.create(title: "New"); let loaded = await waitUntil { if case .loaded = store.state { return true }; return false }; XCTAssertTrue(loaded); let recorded = await recorder.firstRequest(); let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.location.path, "/approved"); XCTAssertTrue(request.id.rawValue.range(of: #"^ses"#, options: .regularExpression) != nil); XCTAssertEqual(try prefs.load().lastSessionID, request.id)
    }

    @MainActor func testCreateRejectedDoesNotFabricateAndCallsOnce() async {
        let recorder = CreateRecorder(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await recorder.record(request); throw SessionAPIError.backend(statusCode: 400) }); store.create(); let rejected = await waitUntil { store.state == .creationRejected(.backend(400)) }; XCTAssertTrue(rejected); XCTAssertNil(store.activeSession); let count = await recorder.count(); XCTAssertEqual(count, 1)
    }

    @MainActor func testCreateAmbiguousTransportFailureIsUnknownAndNotRetried() async {
        let recorder = CreateRecorder(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await recorder.record(request); throw SessionAPIError.requestFailed }); store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown); XCTAssertNil(store.activeSession); let count = await recorder.count(); XCTAssertEqual(count, 1)
    }

    @MainActor func testCreateAmbiguousMalformedResponseIsUnknown() async {
        let recorder = CreateRecorder(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await recorder.record(request); throw SessionAPIError.malformedResponse }); store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown); let count = await recorder.count(); XCTAssertEqual(count, 1)
    }

    @MainActor func testCreateBackendServerFailureIsUnknown() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { _ in throw SessionAPIError.backend(statusCode: 500) }); store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown)
    }

    @MainActor func testCreateReentryIsIgnoredWhileCreationIsInFlight() async {
        let gate = CreateGate(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await gate.enter(request); return self.summary(request.id.rawValue) })
        store.create(); await gate.waitUntilEntered(); store.create(); XCTAssertEqual(store.state, .creating); let count = await gate.count(); XCTAssertEqual(count, 1); await gate.release()
    }

    @MainActor func testSelectRootDuringUnresolvedCreationIsIgnored() async {
        let recorder = CreateRecorder(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await recorder.record(request); throw SessionAPIError.requestFailed })
        store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown)
        store.selectRoot(SessionID(rawValue: "ses-other")); XCTAssertTrue({ if case .creationUnknown = store.state { return true }; return false }()); let count = await recorder.count(); XCTAssertEqual(count, 1)
    }

    @MainActor func testSelectRootDuringCreationIsIgnored() async {
        let gate = CreateGate(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { request in await gate.enter(request); return self.summary(request.id.rawValue) })
        store.create(); await gate.waitUntilEntered(); store.selectRoot(SessionID(rawValue: "ses-other")); XCTAssertEqual(store.state, .creating); let count = await gate.count(); XCTAssertEqual(count, 1); await gate.release()
    }

    @MainActor func testCreateWhileLoadingIsIgnored() async {
        let gate = LoadGate(); let recorder = CreateRecorder(); let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), get: { _ in await gate.wait() }, create: { request in await recorder.record(request); return self.summary(request.id.rawValue) })
        store.load(SessionID(rawValue: "ses-loading")); XCTAssertEqual(store.state, .loading); store.create(); let count = await recorder.count(); XCTAssertEqual(count, 0); await gate.release(self.summary("ses-loading"))
    }

    @MainActor func testLocationSelectDoesNotOverwriteUnreadablePreferences() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-Unreadable-\(UUID().uuidString)")
        let prefs = LocalPreferencesStore(baseDirectory: base); let original = Data(#"{"schemaVersion":99,"selectedDirectoryPath":"/future"}"#.utf8); try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true); try original.write(to: prefs.fileURL)
        let directory = URL(fileURLWithPath: "/approved"); let store = ActiveLocationStore(preferences: prefs, availability: { _ in .directory }, resolve: { directory in ResolvedLocation(directory: directory, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: directory, canonical: directory)) })
        store.select(directory); for _ in 0..<10 { await Task.yield() }; XCTAssertEqual(try Data(contentsOf: prefs.fileURL), original)
    }

    @MainActor func testCreateWithoutLocationRejectsAndDoesNotCallCreate() async {
        let recorder = CreateRecorder(); let store = makeStore(create: { request in await recorder.record(request); return self.summary() }); store.create(); XCTAssertEqual(store.state, .creationRejected(.noLocation)); let count = await recorder.count(); XCTAssertEqual(count, 0)
    }

    @MainActor func testRecoverUnknownCreationFoundLoadsSession() async throws {
        let prefs = preferences(); let recorder = CreateRecorder(); let store = makeStore(preferences: prefs, location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), get: { id in self.summary(id.rawValue, title: "Found") }, create: { request in await recorder.record(request); throw SessionAPIError.requestFailed }); store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown); let request = await recorder.firstRequest(); let requestValue = try XCTUnwrap(request); let expected = summary(requestValue.id.rawValue, title: "Found"); store.recoverUnknownCreation(); let loaded = await waitUntil { store.state == .loaded(expected) }; XCTAssertTrue(loaded); XCTAssertEqual(try prefs.load().lastSessionID, requestValue.id)
    }

    @MainActor func testRecoverUnknownCreationNotFoundIsEmpty() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), get: { _ in throw SessionAPIError.notFound }, create: { _ in throw SessionAPIError.requestFailed }); store.create(); let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }; XCTAssertTrue(unknown); store.recoverUnknownCreation(); let empty = await waitUntil { store.state == .empty }; XCTAssertTrue(empty)
    }

    @MainActor func testStaleLoadGenerationCannotPublish() async {
        let gate = LoadGate(); let a = summary("ses-A"); let b = summary("ses-B"); let store = makeStore(get: { id in if id == a.id { return await gate.wait() }; return b }); store.load(a.id); await gate.waitUntilEntered(); store.load(b.id); let loaded = await waitUntil { store.state == .loaded(b) }; XCTAssertTrue(loaded); await gate.release(a); try? await Task.sleep(for: .milliseconds(40)); XCTAssertEqual(store.state, .loaded(b))
    }

    @MainActor private func makeStore(preferences: LocalPreferencesStore? = nil, location: ActiveLocationProviding = FakeLocationProvider(), connectionBox: ConnectionBox? = nil, list: @escaping @Sendable (SessionListQuery) async throws -> SessionPage = { _ in SessionPage(sessions: [], nextCursor: nil, previousCursor: nil) }, get: @escaping @Sendable (SessionID) async throws -> SessionSummary = { _ in SessionSummary(info: SessionInfo(id: "ses-1", parentID: nil, projectID: "p", title: "T", location: LocationRef(directory: "/work"))) }, create: @escaping @Sendable (SessionCreateRequest) async throws -> SessionSummary = { _ in throw SessionAPIError.requestFailed }, rename: @escaping @Sendable (SessionID, String) async throws -> SessionRenameOutcome = { _, _ in .rejected(.notConnected, authoritative: nil) }) -> ActiveSessionStore {
        ActiveSessionStore(preferences: preferences ?? self.preferences(), location: location, list: list, get: get, create: create, rename: rename, connectionReady: { guard let box = connectionBox else { return true }; return box.generation != nil }, connectionGeneration: { connectionBox?.generation })
    }

    @MainActor func testLoadCompletingBeforeRefreshKeepsActiveAndAdoptsRoots() async {
        let loaded = summary("ses-1", title: "Loaded Title")
        let stale = summary("ses-1", title: "Stale Roots Title")
        let other = summary("ses-2", title: "Other")
        let pageGate = PageGate()
        let loadGate = LoadGate()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in await pageGate.wait() }, get: { _ in await loadGate.wait() })
        store.refreshRoots()
        await pageGate.waitUntilEntered()
        store.load(SessionID(rawValue: "ses-1"))
        await loadGate.waitUntilEntered()
        await loadGate.release(loaded)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        await pageGate.release(SessionPage(sessions: [stale, other], nextCursor: nil, previousCursor: nil))
        let rootsDone = await waitUntil { store.roots.count == 2 }
        XCTAssertTrue(rootsDone)
        XCTAssertEqual(store.activeSession?.title, "Loaded Title")
        XCTAssertEqual(store.roots.first(where: { $0.id.rawValue == "ses-1" })?.title, "Loaded Title")
        XCTAssertEqual(store.roots.first(where: { $0.id.rawValue == "ses-2" })?.title, "Other")
    }

    @MainActor func testRefreshCompletingWhileLoadPendingReconcilesOnLoad() async {
        let loaded = summary("ses-1", title: "Loaded Title")
        let listed = summary("ses-1", title: "Roots Title")
        let other = summary("ses-2", title: "Other")
        let pageGate = PageGate()
        let loadGate = LoadGate()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in await pageGate.wait() }, get: { _ in await loadGate.wait() })
        store.refreshRoots()
        await pageGate.waitUntilEntered()
        store.load(SessionID(rawValue: "ses-1"))
        await loadGate.waitUntilEntered()
        // The refresh completes while the load is still pending: roots publish
        // without an active session to reconcile.
        await pageGate.release(SessionPage(sessions: [listed, other], nextCursor: nil, previousCursor: nil))
        let rootsDone = await waitUntil { store.roots.count == 2 }
        XCTAssertTrue(rootsDone)
        XCTAssertEqual(store.roots.first(where: { $0.id.rawValue == "ses-1" })?.title, "Roots Title")
        // The load then completes and reconciles the listed row authoritatively.
        await loadGate.release(loaded)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        XCTAssertEqual(store.roots.first(where: { $0.id.rawValue == "ses-1" })?.title, "Loaded Title")
        XCTAssertEqual(store.roots.first(where: { $0.id.rawValue == "ses-2" })?.title, "Other")
    }

    @MainActor func testRefreshFailureDuringLoadLeavesLoadingAlone() async {
        let loaded = summary("ses-1", title: "Loaded")
        let loadGate = LoadGate()
        let signal = ListStartedSignal()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { _ in await signal.mark(); throw SessionAPIError.requestFailed }, get: { _ in await loadGate.wait() })
        store.load(SessionID(rawValue: "ses-1"))
        XCTAssertEqual(store.state, .loading)
        store.refreshRoots()
        await signal.wait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.state, .loading)
        await loadGate.release(loaded)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
    }

    @MainActor func testDisconnectedMountRetriesAfterConnectionWithDuplicateSuppression() async throws {
        let prefs = preferences()
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let box = ConnectionBox(generation: nil)
        let expected = summary(title: "Server")
        let gets = GetRecorder()
        let store = makeStore(preferences: prefs, connectionBox: box, get: { id in await gets.record(id); guard box.generation != nil else { throw SessionAPIError.notConnected }; return expected })
        // No read is dispatched while not ready; the restore stays pending.
        store.restore()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.state, .failed(.notConnected))
        let beforeConnect = await gets.callCount()
        XCTAssertEqual(beforeConnect, 0)
        box.generation = 1
        store.noteConnectionContext(1)
        let loaded = await waitUntil { store.state == .loaded(expected) }
        XCTAssertTrue(loaded)
        let afterConnect = await gets.callCount()
        XCTAssertEqual(afterConnect, 1)
        store.noteConnectionContext(1)
        for _ in 0..<10 { await MainActor.run {} }
        let afterDuplicate = await gets.callCount()
        XCTAssertEqual(afterDuplicate, 1)
        XCTAssertEqual(store.state, .loaded(expected))
    }

    @MainActor func testRestoreIfNeededDisconnectedDefersReadUntilConnection() async throws {
        let prefs = preferences()
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let box = ConnectionBox(generation: nil)
        let expected = summary(title: "Server")
        let gets = GetRecorder()
        let store = makeStore(preferences: prefs, connectionBox: box, get: { id in await gets.record(id); return expected })
        store.restoreIfNeeded()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.state, .failed(.notConnected))
        let deferred = await gets.callCount()
        XCTAssertEqual(deferred, 0)
        box.generation = 1
        store.noteConnectionContext(1)
        let loaded = await waitUntil { store.state == .loaded(expected) }
        XCTAssertTrue(loaded)
        let retried = await gets.callCount()
        XCTAssertEqual(retried, 1)
    }

    @MainActor func testExplicitLoadBeforeMountSuppressesAutomaticRestore() async throws {
        let prefs = preferences()
        let persistedID = SessionID(rawValue: "ses-persisted")
        try prefs.save(LocalPreferences(lastSessionID: persistedID))
        let persisted = summary("ses-persisted", title: "Persisted")
        let selected = summary("ses-selected", title: "Selected")
        let gets = GetRecorder()
        let store = makeStore(preferences: prefs, get: { id in await gets.record(id); if id == persistedID { return persisted }; return selected })
        store.load(selected.id)
        let done = await waitUntil { store.state == .loaded(selected) }
        XCTAssertTrue(done)
        let beforeMount = await gets.callCount()
        XCTAssertEqual(beforeMount, 1)
        store.restoreIfNeeded()
        for _ in 0..<10 { await MainActor.run {} }
        let afterMount = await gets.callCount()
        XCTAssertEqual(afterMount, 1)
        XCTAssertEqual(store.state, .loaded(selected))
    }

    @MainActor func testExplicitSelectionSupersedesInFlightRestore() async throws {
        let prefs = preferences()
        let restoreID = SessionID(rawValue: "ses-restore")
        try prefs.save(LocalPreferences(lastSessionID: restoreID))
        let restoreValue = summary("ses-restore", title: "Restore")
        let selected = summary("ses-selected", title: "Selected")
        let gate = LoadGate()
        let gets = GetRecorder()
        let store = makeStore(preferences: prefs, get: { id in await gets.record(id); if id == restoreID { return await gate.wait() }; return selected })
        store.restore()
        await gate.waitUntilEntered()
        XCTAssertEqual(store.state, .loading)
        store.selectRoot(selected.id)
        let done = await waitUntil { store.state == .loaded(selected) }
        XCTAssertTrue(done)
        await gate.release(restoreValue)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .loaded(selected))
        let total = await gets.callCount()
        XCTAssertEqual(total, 2)
    }

    @MainActor func testDuplicateRestoreWhileInFlightIssuesOneRead() async throws {
        let prefs = preferences()
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let expected = summary()
        let gate = LoadGate()
        let gets = GetRecorder()
        let store = makeStore(preferences: prefs, get: { id in await gets.record(id); return await gate.wait() })
        store.restore()
        await gate.waitUntilEntered()
        store.restore()
        store.restoreIfNeeded()
        for _ in 0..<10 { await MainActor.run {} }
        let suppressed = await gets.callCount()
        XCTAssertEqual(suppressed, 1)
        await gate.release(expected)
        let done = await waitUntil { store.state == .loaded(expected) }
        XCTAssertTrue(done)
        let total = await gets.callCount()
        XCTAssertEqual(total, 1)
    }

    @MainActor func testConnectionGenerationReplacementDoesNotAdoptStaleRestore() async throws {
        let prefs = preferences()
        try prefs.save(LocalPreferences(lastSessionID: SessionID(rawValue: "ses-1")))
        let box = ConnectionBox(generation: 1)
        let stale = summary(title: "Stale")
        let expected = summary(title: "Fresh")
        let gate = LoadGate()
        let calls = CallCounter()
        let store = makeStore(preferences: prefs, connectionBox: box, get: { _ in let n = await calls.increment(); if n == 1 { return await gate.wait() }; return expected })
        store.restore()
        await gate.waitUntilEntered()
        box.generation = 2
        store.noteConnectionContext(2)
        await gate.release(stale)
        let done = await waitUntil { store.state == .loaded(expected) }
        XCTAssertTrue(done)
        let total = await calls.count
        XCTAssertEqual(total, 2)
        XCTAssertEqual(store.activeSession?.title, "Fresh")
    }

    @MainActor func testSentCreateLosingConnectionStaysUnknownWithoutPublishing() async throws {
        let box = ConnectionBox(generation: 1)
        let gate = CreateGate()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), connectionBox: box, create: { request in await gate.enter(request); return self.summary(request.id.rawValue, title: "Created") })
        store.create(title: "New")
        XCTAssertEqual(store.state, .creating)
        await gate.waitUntilEntered()
        box.generation = 2
        await gate.release()
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testCancelledReadResolvesLoadingInsteadOfSticking() async {
        let store = makeStore(get: { _ in throw CancellationError() })
        store.load(SessionID(rawValue: "ses-1"))
        XCTAssertEqual(store.state, .loading)
        let settled = await waitUntil { store.state == .empty }
        XCTAssertTrue(settled)
    }

    @MainActor func testStaleRefreshSuccessDoesNotPublish() async {
        let box = ConnectionBox(generation: 1)
        let old = summary("ses-1", title: "Old")
        let fresh = summary("ses-1", title: "Fresh")
        let other = summary("ses-2", title: "Other")
        let pageGate = PageGate()
        let calls = CallCounter()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), connectionBox: box, list: { _ in let n = await calls.increment(); if n == 1 { return SessionPage(sessions: [old], nextCursor: nil, previousCursor: nil) }; return await pageGate.wait() })
        store.refreshRoots()
        let settled = await waitUntil { store.roots.count == 1 }
        XCTAssertTrue(settled)
        store.refreshRoots()
        await pageGate.waitUntilEntered()
        box.generation = 2
        await pageGate.release(SessionPage(sessions: [fresh, other], nextCursor: nil, previousCursor: nil))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.roots.count, 1)
        XCTAssertEqual(store.roots.first?.title, "Old")
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testStaleRefreshErrorLeavesSettledState() async {
        let box = ConnectionBox(generation: 1)
        let calls = CallCounter()
        let errSignal = ListStartedSignal()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), connectionBox: box, list: { _ in let n = await calls.increment(); if n == 1 { throw SessionAPIError.requestFailed }; await errSignal.wait(); throw SessionAPIError.unauthorized })
        store.refreshRoots()
        let failed = await waitUntil { store.state == .failed(.requestFailed) }
        XCTAssertTrue(failed)
        store.refreshRoots()
        while await calls.count < 2 { await Task.yield() }
        box.generation = 2
        await errSignal.mark()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.state, .failed(.requestFailed))
    }

    @MainActor func testRenameCancellationWithStableConnectionIsUnknownPreservingDraft() async {
        let loaded = summary("ses-1", title: "Original")
        let calls = CallCounter()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), get: { _ in loaded }, rename: { _, _ in let _ = await calls.increment(); throw CancellationError() })
        store.load(loaded.id)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }
        XCTAssertTrue(unknown)
        if case .unknown(let request, let serverTitle) = store.renameState {
            XCTAssertEqual(request.sessionID, loaded.id)
            XCTAssertEqual(request.title, "New")
            XCTAssertNil(serverTitle)
        } else { XCTFail("Expected unknown rename state") }
        let dispatched = await calls.count
        XCTAssertEqual(dispatched, 1)
        XCTAssertEqual(store.activeSession?.title, "Original")
    }

    @MainActor func testRenameCancellationAfterConnectionLossStaysUnknown() async {
        let box = ConnectionBox(generation: 1)
        let loaded = summary("ses-1", title: "Original")
        let gate = ThrowGate()
        let store = makeStore(connectionBox: box, get: { _ in loaded }, rename: { _, _ in await gate.wait(); throw CancellationError() })
        store.load(loaded.id)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        store.rename("New")
        await gate.waitUntilEntered()
        box.generation = 2
        await gate.release()
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }
        XCTAssertTrue(unknown)
        if case .unknown(_, let serverTitle) = store.renameState { XCTAssertNil(serverTitle) }
        else { XCTFail("Expected unknown rename state") }
        XCTAssertEqual(store.activeSession?.title, "Original")
    }

    @MainActor func testCancelledCreateStaysUnknown() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { _ in throw CancellationError() })
        store.create(title: "New")
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testCancelledCreateAfterConnectionLossStaysUnknown() async {
        let box = ConnectionBox(generation: 1)
        let gate = CreateGate()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), connectionBox: box, create: { request in await gate.enter(request); throw CancellationError() })
        store.create(title: "New")
        XCTAssertEqual(store.state, .creating)
        await gate.waitUntilEntered()
        box.generation = 2
        await gate.release()
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testCreateWhileDisconnectedRejectsWithoutDispatching() async {
        let box = ConnectionBox(generation: nil)
        let recorder = CreateRecorder()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), connectionBox: box, create: { request in await recorder.record(request); return self.summary(request.id.rawValue) })
        store.create(title: "New")
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.state, .creationRejected(.notConnected))
        let dispatched = await recorder.count()
        XCTAssertEqual(dispatched, 0)
    }

    @MainActor func testRenameWhileDisconnectedRejectsWithoutDispatching() async {
        let box = ConnectionBox(generation: nil)
        let loaded = summary("ses-1", title: "Original")
        let calls = CallCounter()
        let store = makeStore(connectionBox: box, get: { _ in loaded }, rename: { _, _ in let _ = await calls.increment(); return .applied(authoritative: nil) })
        store.load(loaded.id)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        store.rename("New")
        for _ in 0..<10 { await MainActor.run {} }
        if case .rejected(let request, let problem, let serverTitle) = store.renameState {
            XCTAssertEqual(request.title, "New")
            XCTAssertEqual(problem, .notConnected)
            XCTAssertNil(serverTitle)
        } else { XCTFail("Expected rejected rename state, got \(store.renameState)") }
        let dispatched = await calls.count
        XCTAssertEqual(dispatched, 0)
        XCTAssertEqual(store.activeSession?.title, "Original")
    }

    @MainActor func testRefreshRootsQueriesChosenDirectory() async {
        let queries = QueryRecorder()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), list: { query in await queries.record(query); return SessionPage(sessions: [], nextCursor: nil, previousCursor: nil) })
        store.refreshRoots()
        var seen = false
        for _ in 0..<80 {
            if await queries.count() > 0 { seen = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(seen)
        let query = await queries.first()
        let value = try? XCTUnwrap(query)
        XCTAssertEqual(value?.parent, .roots)
        XCTAssertEqual(value?.directory?.path, "/work")
    }

    @MainActor func testRefreshRootsWithoutDirectoryClearsWithoutRequest() async {
        let folder = FakeLocationProvider(active: URL(fileURLWithPath: "/a"))
        let calls = CallCounter()
        let listed = summary("ses-1", title: "Listed")
        let store = makeStore(location: folder, list: { _ in let _ = await calls.increment(); return SessionPage(sessions: [listed], nextCursor: nil, previousCursor: nil) })
        store.refreshRoots()
        let shown = await waitUntil { store.roots.count == 1 }
        XCTAssertTrue(shown)
        folder.activeLocation = nil
        store.refreshRoots()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.roots.isEmpty)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
    }

    @MainActor func testBrowsingOtherFolderKeepsPinnedActiveSession() async {
        let active = summary("ses-A", title: "Pinned A", directory: "/a")
        let folder = FakeLocationProvider(active: URL(fileURLWithPath: "/b"))
        let browsed = summary("ses-B", title: "Browsed B", directory: "/b")
        let store = makeStore(location: folder, list: { _ in SessionPage(sessions: [browsed], nextCursor: nil, previousCursor: nil) }, get: { _ in active })
        store.load(active.id)
        let done = await waitUntil { store.state == .loaded(active) }
        XCTAssertTrue(done)
        store.refreshRoots()
        let rootsDone = await waitUntil { store.roots.count == 1 }
        XCTAssertTrue(rootsDone)
        XCTAssertEqual(store.activeSession?.id, active.id)
        XCTAssertEqual(store.activeSession?.title, "Pinned A")
        XCTAssertEqual(store.roots.first?.id.rawValue, "ses-B")
    }

    @MainActor func testDelayedRootsAfterFolderChangeDropped() async {
        let folder = FakeLocationProvider(active: URL(fileURLWithPath: "/a"))
        let gateA = PageGate()
        let pageA = SessionPage(sessions: [self.summary("ses-A", title: "Stale A")], nextCursor: nil, previousCursor: nil)
        let pageB = SessionPage(sessions: [self.summary("ses-B", title: "Fresh B")], nextCursor: nil, previousCursor: nil)
        let store = makeStore(location: folder, list: { query in if query.directory?.path == "/a" { return await gateA.wait() }; return pageB })
        store.refreshRoots()
        await gateA.waitUntilEntered()
        folder.activeLocation = ResolvedLocation(directory: URL(fileURLWithPath: "/b"), project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: URL(fileURLWithPath: "/b"), canonical: URL(fileURLWithPath: "/b")))
        store.refreshRoots()
        let fresh = await waitUntil { store.roots.first?.title == "Fresh B" }
        XCTAssertTrue(fresh)
        await gateA.release(pageA)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.roots.count, 1)
        XCTAssertEqual(store.roots.first?.title, "Fresh B")
    }

    @MainActor func testQueuedRenameDoesNotDispatchAfterConnectionReplaced() async {
        let box = ConnectionBox(generation: 1)
        let loaded = summary("ses-1", title: "Original")
        let calls = CallCounter()
        let store = makeStore(connectionBox: box, get: { _ in loaded }, rename: { _, _ in let _ = await calls.increment(); return .applied(authoritative: nil) })
        store.load(loaded.id)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        store.rename("Queued")
        box.generation = 2
        let rejected = await waitUntil { if case .rejected = store.renameState { return true }; return false }
        XCTAssertTrue(rejected)
        let callCount = await calls.count
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(store.activeSession?.title, "Original")
    }

    @MainActor func testQueuedCreateDoesNotDispatchAfterConnectionReplaced() async {
        let box = ConnectionBox(generation: 1)
        let recorder = CreateRecorder()
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), connectionBox: box, create: { request in await recorder.record(request); return self.summary(request.id.rawValue) })
        store.create(title: "Queued")
        box.generation = 2
        let rejected = await waitUntil { store.state == .creationRejected(.notConnected) }
        XCTAssertTrue(rejected)
        let callCount = await recorder.count()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testQueuedLoadDoesNotDispatchAfterConnectionReplaced() async {
        let box = ConnectionBox(generation: 1)
        let gets = GetRecorder()
        let store = makeStore(connectionBox: box, get: { id in await gets.record(id); return self.summary(id.rawValue) })
        store.load(SessionID(rawValue: "ses-1"))
        box.generation = 2
        for _ in 0..<20 { await Task.yield() }
        let callCount = await gets.callCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(store.state, .empty)
    }

    @MainActor func testLoadWithMismatchedIDDoesNotPublish() async {
        let wrong = summary("ses-other", title: "Wrong")
        let store = makeStore(get: { _ in wrong })
        store.load(SessionID(rawValue: "ses-1"))
        let settled = await waitUntil { store.state == .failed(.requestFailed) }
        XCTAssertTrue(settled)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testCreateWithMismatchedIDStaysUnknown() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), create: { _ in self.summary("ses-other", title: "Wrong") })
        store.create(title: "New")
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testRecoverUnknownCreationWithMismatchedIDStaysUnknown() async {
        let store = makeStore(location: FakeLocationProvider(active: URL(fileURLWithPath: "/a")), get: { _ in self.summary("ses-other", title: "Wrong") }, create: { _ in throw SessionAPIError.requestFailed })
        store.create(title: "New")
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        guard case .creationUnknown(let id) = store.state else { return XCTFail("Expected creationUnknown") }
        store.recoverUnknownCreation()
        for _ in 0..<20 { await Task.yield() }
        guard case .creationUnknown(let still) = store.state else { return XCTFail("Mismatched recovery must stay unknown, got \(store.state)") }
        XCTAssertEqual(still, id)
        XCTAssertNil(store.activeSession)
    }

    @MainActor func testCheckRenameWithWrongIDStaysUnknown() async {
        let loaded = summary("ses-1", title: "Original")
        let getCount = SendableCounter()
        let store = makeStore(get: { _ in
            let count = await getCount.increment()
            if count <= 1 { return loaded }
            return self.summary("ses-wrong", title: "New")
        }, rename: { _, _ in SessionRenameOutcome.unknown(SessionProblem.requestFailed, authoritative: nil) })
        store.load(loaded.id)
        let done = await waitUntil { store.state == .loaded(loaded) }
        XCTAssertTrue(done)
        store.rename("New")
        let unknown = await waitUntil { if case .unknown = store.renameState { return true }; return false }
        XCTAssertTrue(unknown)
        store.checkRename()
        for _ in 0..<20 { await Task.yield() }
        if case .unknown(let request, _) = store.renameState {
            XCTAssertEqual(request.title, "New")
        } else { XCTFail("Wrong-ID readback must not clear uncertainty, got \(store.renameState)") }
        XCTAssertEqual(store.activeSession?.id.rawValue, "ses-1")
    }
}

@MainActor private final class FakeLocationProvider: ActiveLocationProviding {
    var activeLocation: ResolvedLocation?
    init(active: URL? = nil) { if let active { activeLocation = ResolvedLocation(directory: active, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: active, canonical: active)) } }
}

private actor CapturingTransport: HTTPTransport {
    let response: HTTPResponse; let thrown: HTTPTransportError?; private(set) var lastRequest: HTTPRequest?
    init(response: HTTPResponse, error: HTTPTransportError? = nil) { self.response = response; thrown = error }
    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse { lastRequest = request; if let thrown { throw thrown }; return response }
}

private actor CreateRecorder {
    private(set) var recordedRequests: [SessionCreateRequest] = []
    func count() -> Int { recordedRequests.count }
    func firstRequest() -> SessionCreateRequest? { recordedRequests.first }
    func record(_ request: SessionCreateRequest) { recordedRequests.append(request) }
}

private actor ListStartedSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    func mark() { started = true; continuation?.resume(); continuation = nil }
    func wait() async { if started { return }; await withCheckedContinuation { continuation = $0 } }
}

private actor GetRecorder {
    private(set) var recordedIDs: [SessionID] = []
    func record(_ id: SessionID) { recordedIDs.append(id) }
    func callCount() -> Int { recordedIDs.count }
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

private actor PageGate {
    private var continuation: CheckedContinuation<SessionPage, Never>?
    private var entered = false
    func wait() async -> SessionPage { await withCheckedContinuation { continuation = $0; entered = true } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release(_ page: SessionPage) { continuation?.resume(returning: page); continuation = nil }
}

private actor ThrowGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

private actor SendableCounter {
    private var value: Int = 0
    func increment() -> Int { value += 1; return value }
}

private actor QueryRecorder {
    private var queries: [SessionListQuery] = []
    func record(_ query: SessionListQuery) { queries.append(query) }
    func count() -> Int { queries.count }
    func first() -> SessionListQuery? { queries.first }
}

private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var boxed: UInt64?
    var generation: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return boxed }
        set { lock.lock(); defer { lock.unlock() }; boxed = newValue }
    }
    init(generation: UInt64? = 1) { boxed = generation }
}

private struct TestCredentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private final class SessionPersistFailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    var isFailing: Bool { get { lock.lock(); defer { lock.unlock() }; return failing } set { lock.lock(); failing = newValue; lock.unlock() } }
}

extension SessionStoreTests {
    @MainActor private func failingPrefs(_ toggle: SessionPersistFailSwitch = SessionPersistFailSwitch()) throws -> (failing: LocalPreferencesStore, working: LocalPreferencesStore) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-SessionsFail-\(UUID().uuidString)").appendingPathComponent("p.json")
        let working = LocalPreferencesStore(fileURL: file)
        try working.save(.default)
        let failing = LocalPreferencesStore(fileURL: file, replacingItem: { existing, temp in
            if toggle.isFailing { throw CocoaError(.fileWriteUnknown) }
            _ = try FileManager.default.replaceItemAt(existing, withItemAt: temp)
        })
        return (failing, working)
    }

    @MainActor private func assertFreshStoreRestoresNothing(_ working: LocalPreferencesStore, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = makeStore(preferences: working)
        fresh.restore()
        XCTAssertEqual(fresh.state, .empty, file: file, line: line)
        XCTAssertNil(try? working.load().lastSessionID, file: file, line: line)
    }

    @MainActor func testPersistFailureOnCreateStaysLoadedWithWarning() async throws {
        let prefs = try failingPrefs()
        let store = makeStore(preferences: prefs.failing, location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), create: { [self] request in summary(request.id.rawValue) })
        XCTAssertNil(store.persistenceProblem)
        store.create()
        let loaded = await waitUntil { store.activeSession != nil }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.persistenceProblem, .saveFailed)
        assertFreshStoreRestoresNothing(prefs.working)
    }

    @MainActor func testPersistFailureOnLoadStaysLoadedWithWarning() async throws {
        let prefs = try failingPrefs()
        let value = summary("ses-9")
        let store = makeStore(preferences: prefs.failing, get: { _ in value })
        store.load(value.id)
        let loaded = await waitUntil { store.state == .loaded(value) }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.persistenceProblem, .saveFailed)
        assertFreshStoreRestoresNothing(prefs.working)
    }

    @MainActor func testPersistFailureOnRecoverUnknownCreationStaysLoadedWithWarning() async throws {
        let prefs = try failingPrefs()
        let store = makeStore(preferences: prefs.failing, location: FakeLocationProvider(active: URL(fileURLWithPath: "/work")), get: { [self] id in summary(id.rawValue) }, create: { _ in throw SessionAPIError.requestFailed })
        store.create()
        let unknown = await waitUntil { if case .creationUnknown = store.state { return true }; return false }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.persistenceProblem)
        store.recoverUnknownCreation()
        let loaded = await waitUntil { store.activeSession != nil }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.persistenceProblem, .saveFailed)
        assertFreshStoreRestoresNothing(prefs.working)
    }

    @MainActor func testLaterSuccessfulPersistClearsWarning() async throws {
        let toggle = SessionPersistFailSwitch()
        let prefs = try failingPrefs(toggle)
        let value = summary("ses-9")
        let store = makeStore(preferences: prefs.failing, get: { _ in value })
        store.load(value.id)
        let warned = await waitUntil { store.persistenceProblem == .saveFailed }
        XCTAssertTrue(warned)
        toggle.isFailing = false
        store.load(value.id)
        let cleared = await waitUntil { store.persistenceProblem == nil && store.state == .loaded(value) }
        XCTAssertTrue(cleared)
        XCTAssertEqual(try prefs.working.load().lastSessionID, value.id)
    }

    @MainActor func testClearFailureWarnsAndSuccessfulPathsSetNoWarning() async throws {
        let ok = makeStore(get: { [self] _ in summary("ses-9") })
        ok.load(SessionID(rawValue: "ses-9"))
        let loaded = await waitUntil { ok.activeSession != nil }
        XCTAssertTrue(loaded)
        XCTAssertNil(ok.persistenceProblem)
        ok.clear()
        XCTAssertNil(ok.persistenceProblem)

        let prefs = try failingPrefs()
        let bad = makeStore(preferences: prefs.failing)
        bad.clear()
        XCTAssertEqual(bad.persistenceProblem, .saveFailed)
        XCTAssertEqual(bad.state, .empty)
    }
}
