import Foundation
import XCTest
@testable import Joycode

final class ProjectPickerTests: XCTestCase {
    @MainActor
    func testResolverUsesApprovedLocationAndDecodesProjectIdentity() async throws {
        let directory = URL(fileURLWithPath: "/work/tree")
        let transport = CapturingTransport(response: HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"directory":"/work/tree","project":{"id":"project-1","directory":"/work/tree","canonical":"/work"}}"#.utf8)
        ))

        let value = try await LocationResolver(transport: transport).resolve(connection: connection(), directory: directory)
        let request = await transport.lastRequest
        XCTAssertEqual(request?.method, .get)
        XCTAssertEqual(request?.relativePath, "/api/location")
        XCTAssertEqual(request?.queryItems.count, 1)
        XCTAssertEqual(request?.queryItems.first?.name, "location[directory]")
        XCTAssertEqual(request?.queryItems.first?.value, directory.path)
        XCTAssertEqual(value.directory, directory.path)
        XCTAssertEqual(value.project.id, "project-1")
        XCTAssertEqual(value.project.directory, directory.path)
        XCTAssertEqual(value.project.canonical, "/work")
        XCTAssertNotEqual(value.directory, value.project.canonical)
    }

    @MainActor
    func testResolverMapsTransportAndMalformedResponseErrors() async {
        let cases: [(HTTPTransportError?, Data, LocationResolutionError)] = [
            (.unauthorized, Data(), .unauthorized),
            (.backend(statusCode: 400), Data(), .backend(statusCode: 400)),
            (nil, Data("not-json".utf8), .malformedResponse)
        ]
        for (error, body, expected) in cases {
            let transport = CapturingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: body), error: error)
            do {
                _ = try await LocationResolver(transport: transport).resolve(connection: connection(), directory: URL(fileURLWithPath: "/work"))
                XCTFail("expected \(expected)")
            } catch let actual as LocationResolutionError {
                XCTAssertEqual(actual, expected)
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    @MainActor
    func testDefaultAvailabilityDistinguishesDirectoryMissingAndFile() throws {
        let directory = temporaryDirectory("availability")
        let file = directory.appendingPathComponent("file")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        XCTAssertEqual(ActiveLocationStore.defaultAvailability(directory), .directory)
        XCTAssertEqual(ActiveLocationStore.defaultAvailability(directory.appendingPathComponent("missing")), .missing)
        XCTAssertEqual(ActiveLocationStore.defaultAvailability(file), .notADirectory)
    }

    @MainActor
    func testResolverDecodesDistinctWorktreeLocationsWithSharedProjectID() async throws {
        let firstDirectory = "/worktree/one"
        let secondDirectory = "/worktree/two"
        let firstTransport = CapturingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"directory":"/worktree/one","project":{"id":"shared","directory":"/worktree/one","canonical":"/repo"}}"#.utf8)))
        let secondTransport = CapturingTransport(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"directory":"/worktree/two","project":{"id":"shared","directory":"/worktree/two","canonical":"/repo"}}"#.utf8)))
        let first = try await LocationResolver(transport: firstTransport).resolve(connection: connection(), directory: URL(fileURLWithPath: firstDirectory))
        let second = try await LocationResolver(transport: secondTransport).resolve(connection: connection(), directory: URL(fileURLWithPath: secondDirectory))
        XCTAssertEqual(first.project.id, "shared")
        XCTAssertEqual(second.project.id, "shared")
        XCTAssertEqual(first.directory, firstDirectory)
        XCTAssertEqual(second.directory, secondDirectory)
        XCTAssertNotEqual(first.directory, second.directory)
    }

    @MainActor
    func testLocationRequestComposesApprovedDirectoryURL() throws {
        let directory = URL(fileURLWithPath: "/work/tree with spaces")
        let url = try HTTPRequestBuilder.makeURL(endpoint: connection().endpoint, request: LocationResolver.request(directory: directory))
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "location[directory]" })?.value
        XCTAssertEqual(value, directory.path)
    }

    @MainActor
    func testSelectResolvesApprovedDirectory() async throws {
        let directory = temporaryDirectory("selected")
        let resolved = resolvedLocation(directory: directory, canonical: directory.deletingLastPathComponent())
        let resolver = RecordingResolver(result: resolved)
        let store = makeStore { _ in .directory } resolve: { directory in try await resolver.resolve(directory) }

        store.select(directory)
        XCTAssertEqual(store.state, .resolving(directory: directory))
        let didResolve = await waitUntil { store.state == ActiveLocationState.resolved(resolved) }
        XCTAssertTrue(didResolve)
        let directories = await resolver.directories
        XCTAssertEqual(directories, [directory])
        XCTAssertEqual(store.activeLocation, resolved)
        XCTAssertNotEqual(resolved.directory, resolved.project.canonical)
    }

    @MainActor
    func testCancelledImportLeavesStateAndDoesNotResolve() async throws {
        let resolver = RecordingResolver(result: resolvedLocation(directory: URL(fileURLWithPath: "/unused"), canonical: URL(fileURLWithPath: "/")))
        let store = makeStore { _ in .directory } resolve: { directory in try await resolver.resolve(directory) }
        let model = ProjectPickerModel(store: store)
        let before = store.state

        model.completeImport(Result<URL, Error>.failure(CocoaError(.userCancelled)))
        XCTAssertEqual(store.state, before)
        let directories = await resolver.directories
        XCTAssertTrue(directories.isEmpty)
    }

    @MainActor
    func testMissingAndNonDirectorySelectionsNeedRecoveryWithoutResolving() async throws {
        for (availability, problem) in [(DirectoryAvailability.missing, ActiveLocationProblem.directoryMissing), (.notADirectory, .notADirectory)] {
            let resolver = RecordingResolver(result: resolvedLocation(directory: URL(fileURLWithPath: "/unused"), canonical: URL(fileURLWithPath: "/")))
            let store = makeStore { _ in availability } resolve: { directory in try await resolver.resolve(directory) }
            let directory = URL(fileURLWithPath: "/approved-but-inaccessible")
            store.select(directory)
            XCTAssertEqual(store.state, ActiveLocationState.needsRecovery(directory: directory, problem: problem))
            let directories = await resolver.directories
            XCTAssertTrue(directories.isEmpty)
        }
    }

    @MainActor
    func testNotConnectedLeavesSelectionInSelectedState() async throws {
        let directory = temporaryDirectory("offline")
        let store = makeStore { _ in .directory } resolve: { _ in throw LocationResolutionError.notConnected }
        store.select(directory)
        let didSelect = await waitUntil { store.state == ActiveLocationState.selected(directory: directory) }
        XCTAssertTrue(didSelect)
    }

    @MainActor
    func testRestoreMissingDirectoryNeedsRecoveryEmptyIsEmptyAndValidResolves() async throws {
        let missing = URL(fileURLWithPath: "/gone")
        let prefsDirectory = temporaryDirectory("restore")
        let prefs = LocalPreferencesStore(baseDirectory: prefsDirectory)
        try prefs.save(LocalPreferences(selectedDirectory: missing))
        let missingStore = makeStore(prefs: prefs) { _ in .missing } resolve: { _ in XCTFail("must not resolve"); throw LocationResolutionError.requestFailed }
        missingStore.restore()
        XCTAssertEqual(missingStore.state, .needsRecovery(directory: missing, problem: .directoryMissing))

        let emptyStore = makeStore(prefs: LocalPreferencesStore(baseDirectory: temporaryDirectory("empty"))) { _ in .directory } resolve: { _ in XCTFail("must not resolve"); throw LocationResolutionError.requestFailed }
        emptyStore.restore()
        XCTAssertEqual(emptyStore.state, .empty)

        let valid = temporaryDirectory("valid")
        let validPrefsDirectory = temporaryDirectory("valid-prefs")
        let validPrefs = LocalPreferencesStore(baseDirectory: validPrefsDirectory)
        try validPrefs.save(LocalPreferences(selectedDirectory: valid))
        let value = resolvedLocation(directory: valid, canonical: valid.deletingLastPathComponent())
        let validStore = makeStore(prefs: validPrefs) { _ in .directory } resolve: { _ in value }
        validStore.restore()
        let didResolve = await waitUntil { validStore.state == ActiveLocationState.resolved(value) }
        XCTAssertTrue(didResolve)
    }

    @MainActor
    func testSelectionPersistsAndFreshStoreRestoresIt() async throws {
        let base = temporaryDirectory("round-trip")
        let directory = temporaryDirectory("project")
        let value = resolvedLocation(directory: directory, canonical: directory.deletingLastPathComponent())
        let first = makeStore(prefs: LocalPreferencesStore(baseDirectory: base)) { _ in .directory } resolve: { _ in value }
        first.select(directory)
        let firstResolved = await waitUntil { first.state == ActiveLocationState.resolved(value) }
        XCTAssertTrue(firstResolved)
        XCTAssertEqual(try LocalPreferencesStore(baseDirectory: base).load().selectedDirectory?.path, directory.path)

        let second = makeStore(prefs: LocalPreferencesStore(baseDirectory: base)) { _ in .directory } resolve: { _ in value }
        second.restore()
        let secondResolved = await waitUntil { second.state == ActiveLocationState.resolved(value) }
        XCTAssertTrue(secondResolved)
    }

    @MainActor
    func testSelectionAndClearPreserveLastSessionID() throws {
        let prefs = LocalPreferencesStore(baseDirectory: temporaryDirectory("preserve-session"))
        let sessionID = SessionID(rawValue: "ses-kept")
        try prefs.save(LocalPreferences(selectedDirectory: nil, lastSessionID: sessionID))
        let directory = temporaryDirectory("preserved-directory")
        let resolved = resolvedLocation(directory: directory)
        let store = makeStore(prefs: prefs) { _ in .directory } resolve: { _ in resolved }
        store.select(directory)
        XCTAssertEqual(try prefs.load().lastSessionID, sessionID)
        store.clear()
        XCTAssertEqual(try prefs.load().lastSessionID, sessionID)
    }

    @MainActor
    func testSameProjectIdPreservesDistinctWorktreeLocations() async throws {
        let firstDirectory = temporaryDirectory("worktree-a")
        let secondDirectory = temporaryDirectory("worktree-b")
        let projectID = ProjectID(rawValue: "same-project")
        let first = ResolvedLocation(directory: firstDirectory, project: ProjectIdentity(id: projectID, directory: firstDirectory, canonical: URL(fileURLWithPath: "/repo")))
        let second = ResolvedLocation(directory: secondDirectory, project: ProjectIdentity(id: projectID, directory: secondDirectory, canonical: URL(fileURLWithPath: "/repo")))
        let resolver = RecordingResolver(results: [first, second])
        let store = makeStore { _ in .directory } resolve: { directory in try await resolver.resolve(directory) }
        store.select(firstDirectory)
        let firstResolved = await waitUntil { store.state == ActiveLocationState.resolved(first) }
        XCTAssertTrue(firstResolved)
        store.select(secondDirectory)
        let secondResolved = await waitUntil { store.state == ActiveLocationState.resolved(second) }
        XCTAssertTrue(secondResolved)
        XCTAssertEqual(store.activeLocation?.project.id, projectID)
        XCTAssertEqual(store.activeLocation?.directory, secondDirectory)
        XCTAssertNotEqual(first.directory, first.project.canonical)
        XCTAssertNotEqual(second.directory, second.project.canonical)
    }

    @MainActor
    func testStaleResolutionCannotPublishAfterNewerSelection() async throws {
        let firstDirectory = temporaryDirectory("stale-a")
        let secondDirectory = temporaryDirectory("stale-b")
        let first = resolvedLocation(directory: firstDirectory, canonical: firstDirectory.deletingLastPathComponent())
        let second = resolvedLocation(directory: secondDirectory, canonical: secondDirectory.deletingLastPathComponent())
        let gate = ResolutionGate(firstDirectory: firstDirectory, first: first, second: second)
        let store = makeStore { _ in .directory } resolve: { directory in try await gate.resolve(directory) }
        store.select(firstDirectory)
        let isResolving = await waitUntil { store.state == ActiveLocationState.resolving(directory: firstDirectory) }
        XCTAssertTrue(isResolving)
        store.select(secondDirectory)
        let secondResolved = await waitUntil { store.state == ActiveLocationState.resolved(second) }
        XCTAssertTrue(secondResolved)
        await gate.releaseFirst()
        var firstReturned = false
        for _ in 0..<1000 {
            if await gate.firstResolutionReturned { firstReturned = true; break }
            await Task.yield()
        }
        XCTAssertTrue(firstReturned)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.state, ActiveLocationState.resolved(second))
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        prefs: LocalPreferencesStore = LocalPreferencesStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        _ availability: @escaping @Sendable (URL) -> DirectoryAvailability,
        resolve: @escaping @Sendable (URL) async throws -> ResolvedLocation
    ) -> ActiveLocationStore {
        ActiveLocationStore(preferences: prefs, availability: availability, resolve: resolve)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let attempts = Int(timeout * 20)
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-ProjectPicker-\(name)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func resolvedLocation(directory: URL, canonical: URL = URL(fileURLWithPath: "/repo")) -> ResolvedLocation {
        ResolvedLocation(directory: directory, project: ProjectIdentity(id: ProjectID(rawValue: "project-\(directory.lastPathComponent)"), directory: directory, canonical: canonical))
    }

    private func connection() -> ServiceConnection {
        ServiceConnection(connectionID: ConnectionID(rawValue: "test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!), credentialCapability: TestCredentials())
    }
}

private actor CapturingTransport: HTTPTransport {
    let response: HTTPResponse
    let error: HTTPTransportError?
    private(set) var lastRequest: HTTPRequest?

    init(response: HTTPResponse, error: HTTPTransportError? = nil) { self.response = response; self.error = error }
    func send(connection: ServiceConnection, request: HTTPRequest) async throws -> HTTPResponse {
        lastRequest = request
        if let error { throw error }
        return response
    }
}

private actor RecordingResolver {
    private(set) var directories: [URL] = []
    private var results: [ResolvedLocation]
    init(result: ResolvedLocation) { results = [result] }
    init(results: [ResolvedLocation]) { self.results = results }
    func resolve(_ directory: URL) throws -> ResolvedLocation {
        directories.append(directory)
        return results.removeFirst()
    }
}

private actor ResolutionGate {
    let firstDirectory: URL
    let first: ResolvedLocation
    let second: ResolvedLocation
    private var continuation: CheckedContinuation<ResolvedLocation, Never>?
    private(set) var firstResolutionReturned = false

    init(firstDirectory: URL, first: ResolvedLocation, second: ResolvedLocation) { self.firstDirectory = firstDirectory; self.first = first; self.second = second }
    func resolve(_ directory: URL) async -> ResolvedLocation {
        if directory == firstDirectory {
            let result = await withCheckedContinuation { continuation = $0 }
            firstResolutionReturned = true
            return result
        }
        return second
    }
    func releaseFirst() { continuation?.resume(returning: first); continuation = nil }
}

private struct TestCredentials: CredentialCapability {
    var safeDescription: String { "test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}
