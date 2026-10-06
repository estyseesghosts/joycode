import Combine
import Foundation
import XCTest
@testable import Joycode

/// H03 observation-ownership regression tests.
///
/// Topology under test: `JoycodeApp` owns the stores, `RootView` holds plain
/// references, and each feature view observes exactly the store it renders.
/// The structural rule itself is enforced by API shape (`RootView` exposes no
/// `@ObservedObject` for forwarded stores; `SelectionView(store:)` takes only
/// a `SelectionStore`) plus a source grep gate. These tests pin the runtime
/// consequences: selection renders from one store, and transcript publication
/// emits nothing on unrelated stores.
final class ObservationOwnershipTests: XCTestCase {
    @MainActor
    func testSelectionViewConstructsWithOnlySelectionStore() {
        let store = ObservationSelectionFixtures.selectionStore()
        let view = SelectionView(store: store)
        XCTAssertNotNil(view)
        // Evaluating the body exercises every store read in the view against
        // the single fixture store; no session/location store is involved.
        _ = view.body
    }

    @MainActor
    func testTranscriptPublicationDoesNotEmitOnUnrelatedStores() {
        let model = DiagnosticModel(discover: { ObservationSelectionFixtures.localService() })
        let preferences = LocalPreferencesStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Joycode-Observation-\(UUID().uuidString)")
        )
        let sessionStore = ActiveSessionStore(
            preferences: preferences,
            location: ObservationFakeLocation(),
            list: { _ in SessionPage(sessions: [], nextCursor: nil, previousCursor: nil) },
            get: { _ in throw SessionAPIError.requestFailed },
            create: { _ in throw SessionAPIError.requestFailed }
        )
        let selectionStore = ObservationSelectionFixtures.selectionStore()
        // Nil session/nil connection: refresh publishes transcript state
        // synchronously without touching transport.
        let transcriptStore = TranscriptStore(
            activeSessionID: { nil },
            connectionGeneration: { nil },
            load: { _, _ in throw TranscriptAPIError.requestFailed }
        )

        var unrelatedEmissions = 0
        var cancellables = Set<AnyCancellable>()
        model.objectWillChange.sink { _ in unrelatedEmissions += 1 }.store(in: &cancellables)
        sessionStore.objectWillChange.sink { _ in unrelatedEmissions += 1 }.store(in: &cancellables)
        selectionStore.objectWillChange.sink { _ in unrelatedEmissions += 1 }.store(in: &cancellables)

        var transcriptEmissions = 0
        transcriptStore.objectWillChange.sink { _ in transcriptEmissions += 1 }.store(in: &cancellables)

        transcriptStore.refresh()

        XCTAssertGreaterThan(transcriptEmissions, 0, "The fixture must actually publish transcript state")
        XCTAssertEqual(unrelatedEmissions, 0, "Transcript publication must not emit on diagnostic/session/selection stores")
        withExtendedLifetime(cancellables) {}
    }

    @MainActor
    func testRootViewForwardsReferencesWithoutObserving() {
        let transport: any HTTPTransport = URLSessionHTTPTransport()
        let model = DiagnosticComposition.productionModel(transport: transport)
        let view = RootView(model: model, eventOwner: ConnectionEventOwner(connectionOwner: model), transport: transport)
        XCTAssertNotNil(view)
        _ = view.body
    }
}

@MainActor
private enum ObservationSelectionFixtures {
    static func selectionStore() -> SelectionStore {
        SelectionStore(
            location: ObservationFakeLocation(active: URL(fileURLWithPath: "/work")),
            activeSessionID: { nil },
            listAgents: { _ in [] },
            listModels: { _ in [] },
            selectAgent: { _, _ in .applied(confirmed: nil) },
            selectModel: { _, _ in .applied(confirmed: nil) },
            readSelection: { _ in SelectionConfirmation(agent: nil, model: nil) }
        )
    }

    nonisolated static func localService() -> LocalServiceConnection {
        let connection = ServiceConnection(
            connectionID: ConnectionID(rawValue: "observation-test"),
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://127.0.0.1")!),
            credentialCapability: ObservationTestCredentials()
        )
        return LocalServiceConnection(
            connection: connection,
            registration: ServiceRegistration(url: "http://127.0.0.1", pid: 1, id: nil, version: "2.0.20", password: nil),
            info: ServerInfo(version: "2.0.20", pid: 1, urls: [], paths: .init(tmp: "/tmp"))
        )
    }
}

@MainActor
private final class ObservationFakeLocation: ActiveLocationProviding {
    var activeLocation: ResolvedLocation?
    init(active: URL? = nil) {
        if let active {
            activeLocation = ResolvedLocation(
                directory: active,
                project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: active, canonical: active)
            )
        }
    }
}

private struct ObservationTestCredentials: CredentialCapability {
    var safeDescription: String { "observation-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}
