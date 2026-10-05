import Foundation
import XCTest
@testable import Joycode

// MARK: - Selection adapter tests (SelectionAPI)

final class SelectionAdapterTests: XCTestCase {
    private func connection() -> ServiceConnection {
        ServiceConnection(connectionID: ConnectionID(rawValue: "selection-test"), endpoint: ServiceEndpoint(baseURL: URL(string: "http://localhost")!), credentialCapability: SelectionCredentials())
    }

    // 1. testAgentDiscoveryRequestUsesGetAndLocationQuery
    func testAgentDiscoveryRequestUsesGetAndLocationQuery() {
        let request = SelectionAPI.agentsRequest(location: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/agent")
        XCTAssertEqual(request.queryItems, [.init(name: "location[directory]", value: "/work")])
        XCTAssertNil(request.body)
    }

    // 2. testModelDiscoveryRequestUsesGetAndLocationQuery
    func testModelDiscoveryRequestUsesGetAndLocationQuery() {
        let request = SelectionAPI.modelsRequest(location: URL(fileURLWithPath: "/work"))
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/model")
        XCTAssertEqual(request.queryItems, [.init(name: "location[directory]", value: "/work")])
    }

    // 3. testDiscoveryRequestsOmitLocationWhenNil
    func testDiscoveryRequestsOmitLocationWhenNil() {
        XCTAssertTrue(SelectionAPI.agentsRequest(location: nil).queryItems.isEmpty)
        XCTAssertTrue(SelectionAPI.modelsRequest(location: nil).queryItems.isEmpty)
    }

    // 4. testSwitchAgentRequestUsesPostPathAndBody
    func testSwitchAgentRequestUsesPostPathAndBody() throws {
        let request = SelectionAPI.switchAgentRequest(sessionID: SessionID(rawValue: "ses-1"), agent: "build")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/agent")
        XCTAssertTrue(request.queryItems.isEmpty)
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json["agent"] as? String, "build")
    }

    // 5. testSwitchModelRequestUsesPostPathAndModelRefBody
    func testSwitchModelRequestUsesPostPathAndModelRefBody() throws {
        let request = SelectionAPI.switchModelRequest(sessionID: SessionID(rawValue: "ses-1"), model: ModelRef(id: "claude", providerID: "anthropic"))
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1/model")
        let body = try XCTUnwrap(request.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let model = try XCTUnwrap(json["model"] as? [String: Any])
        XCTAssertEqual(model["id"] as? String, "claude")
        XCTAssertEqual(model["providerID"] as? String, "anthropic")
        XCTAssertNil(model["variant"])
    }

    // 6. testReadSelectionRequestUsesSessionGetPath
    func testReadSelectionRequestUsesSessionGetPath() {
        let request = SelectionAPI.readSelectionRequest(sessionID: SessionID(rawValue: "ses-1"))
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.relativePath, "/api/session/ses-1")
        XCTAssertTrue(request.queryItems.isEmpty)
    }

    // 7. testAgentListDecodesPrimaryModeAndToleratesUnknownFields
    func testAgentListDecodesPrimaryModeAndToleratesUnknownFields() throws {
        let data = Data(#"{"location":{"directory":"/w"},"data":[{"id":"build","name":"Build","mode":"primary","hidden":false,"description":"d","extra":true,"permissions":[],"request":{"settings":{},"headers":{},"body":{}}}]}"#.utf8)
        let agents = try AgentListEnvelope.decode(data).data
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].id, "build")
        XCTAssertEqual(agents[0].name, "Build")
        XCTAssertEqual(agents[0].mode, "primary")
        XCTAssertFalse(agents[0].hidden)
        XCTAssertTrue(AgentSummary(info: agents[0]).isPrimary)
    }

    // 8. testAgentListDefaultsMissingOptionalFields
    func testAgentListDefaultsMissingOptionalFields() throws {
        let data = Data(#"{"data":[{"id":"plan"}]}"#.utf8)
        let agents = try AgentListEnvelope.decode(data).data
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].name, "plan")
        XCTAssertEqual(agents[0].mode, "all")
        XCTAssertFalse(agents[0].hidden)
    }

    // 9. testModelListDecodesEnvelopeAndModelRefShape
    func testModelListDecodesEnvelopeAndModelRefShape() throws {
        let data = Data(#"{"location":{"directory":"/w"},"data":[{"id":"claude","providerID":"anthropic","name":"Claude","enabled":true,"status":"active","variants":[],"cost":[]}]}"#.utf8)
        let models = try ModelListEnvelope.decode(data).data
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "claude")
        XCTAssertEqual(models[0].providerID, "anthropic")
        let summary = ModelSummary(info: models[0])
        XCTAssertEqual(summary.ref, ModelRef(id: "claude", providerID: "anthropic"))
        XCTAssertEqual(summary.name, "Claude")
        XCTAssertTrue(summary.enabled)
    }

    // 10. testMalformedDiscoveryResponseThrows
    func testMalformedDiscoveryResponseThrows() {
        XCTAssertThrowsError(try AgentListEnvelope.decode(Data("bad".utf8))) { XCTAssertEqual($0 as? SelectionAPIError, .malformedResponse) }
        XCTAssertThrowsError(try ModelListEnvelope.decode(Data("bad".utf8))) { XCTAssertEqual($0 as? SelectionAPIError, .malformedResponse) }
        XCTAssertThrowsError(try SessionSelectionEnvelope.decode(Data("bad".utf8))) { XCTAssertEqual($0 as? SelectionAPIError, .malformedResponse) }
    }

    // 11. testListAgentsMapsDeclaredErrors
    func testListAgentsMapsDeclaredErrors() async {
        for (status, expected) in [(400, SelectionAPIError.backend(statusCode: 400)), (401, SelectionAPIError.unauthorized)] {
            let transport = SelectionTestTransport(responses: [(status, Data())])
            do {
                _ = try await SelectionAPI(transport: transport).listAgents(connection: connection(), location: URL(fileURLWithPath: "/w"))
                XCTFail("Expected error for status \(status)")
            } catch let error as SelectionAPIError { XCTAssertEqual(error, expected) }
            catch { XCTFail("Unexpected error \(error)") }
        }
    }

    // 12. testListModelsMaps503ServiceUnavailable
    func testListModelsMaps503ServiceUnavailable() async {
        let transport = SelectionTestTransport(responses: [(503, Data())])
        do {
            _ = try await SelectionAPI(transport: transport).listModels(connection: connection(), location: nil)
            XCTFail("Expected 503")
        } catch let error as SelectionAPIError { XCTAssertEqual(error, .serviceUnavailable) }
        catch { XCTFail("Unexpected error \(error)") }
    }

    // 13. testSelectAgentAppliedPerformsSameConnectionReadback
    func testSelectAgentAppliedPerformsSameConnectionReadback() async throws {
        let readback = Data(#"{"data":{"agent":"build","model":{"id":"claude","providerID":"anthropic"}}}"#.utf8)
        let transport = SelectionTestTransport(responses: [(204, Data()), (200, readback)])
        let api = SelectionAPI(transport: transport)
        let result = try await api.selectAgent(connection: connection(), sessionID: SessionID(rawValue: "ses-1"), agent: "build")
        let requests = await transport.requests
        let connections = await transport.connections
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, .post)
        XCTAssertEqual(requests[0].relativePath, "/api/session/ses-1/agent")
        XCTAssertEqual(requests[1].method, .get)
        XCTAssertEqual(requests[1].relativePath, "/api/session/ses-1")
        XCTAssertEqual(connections[0].connectionID.rawValue, connections[1].connectionID.rawValue, "Mutation and readback must share one connection")
        if case .applied(let confirmed) = result {
            XCTAssertEqual(confirmed?.agent, "build")
            XCTAssertEqual(confirmed?.model, ModelRef(id: "claude", providerID: "anthropic"))
        } else { XCTFail("Expected applied, got \(result)") }
    }

    // 14. testSelectModelDeclaredRejectionIsRejectedWithoutReadback
    func testSelectModelDeclaredRejectionIsRejectedWithoutReadback() async throws {
        let transport = SelectionTestTransport(responses: [(404, Data())])
        let result = try await SelectionAPI(transport: transport).selectModel(connection: connection(), sessionID: SessionID(rawValue: "ses-1"), model: ModelRef(id: "m", providerID: "p"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "A declared rejection must not read back")
        if case .rejected(let error) = result { XCTAssertEqual(error, .notFound) } else { XCTFail("Expected rejected, got \(result)") }
    }

    // 15. testSelectAgentUndeclared500IsUnknownWithoutReadback
    func testSelectAgentUndeclared500IsUnknownWithoutReadback() async throws {
        let transport = SelectionTestTransport(responses: [(500, Data())])
        let result = try await SelectionAPI(transport: transport).selectAgent(connection: connection(), sessionID: SessionID(rawValue: "ses-1"), agent: "build")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        if case .unknown(let error) = result { XCTAssertEqual(error, .backend(statusCode: 500)) } else { XCTFail("Expected unknown, got \(result)") }
    }

    // 16. testSelectionNon204SuccessIsUnknown
    func testSelectionNon204SuccessIsUnknown() async throws {
        let transport = SelectionTestTransport(responses: [(200, Data())])
        let result = try await SelectionAPI(transport: transport).selectAgent(connection: connection(), sessionID: SessionID(rawValue: "ses-1"), agent: "build")
        if case .unknown(let error) = result { XCTAssertEqual(error, .requestFailed) } else { XCTFail("Expected unknown, got \(result)") }
    }

    // 17. testSelectAgentReadbackFailureStillApplied
    func testSelectAgentReadbackFailureStillApplied() async throws {
        let transport = SelectionTestTransport(responses: [(204, Data()), (500, Data())])
        let result = try await SelectionAPI(transport: transport).selectAgent(connection: connection(), sessionID: SessionID(rawValue: "ses-1"), agent: "build")
        if case .applied(let confirmed) = result { XCTAssertNil(confirmed, "A failed readback cannot fabricate confirmation") } else { XCTFail("Expected applied, got \(result)") }
    }

    // 18. testDeclaredSelectionRejectionClassification
    func testDeclaredSelectionRejectionClassification() {
        XCTAssertTrue(SelectionAPI.isDeclaredRejection(.backend(statusCode: 400)))
        XCTAssertTrue(SelectionAPI.isDeclaredRejection(.unauthorized))
        XCTAssertTrue(SelectionAPI.isDeclaredRejection(.notFound))
        XCTAssertFalse(SelectionAPI.isDeclaredRejection(.backend(statusCode: 500)))
        XCTAssertFalse(SelectionAPI.isDeclaredRejection(.serviceUnavailable))
        XCTAssertFalse(SelectionAPI.isDeclaredRejection(.requestFailed))
        XCTAssertFalse(SelectionAPI.isDeclaredRejection(.malformedResponse))
        XCTAssertFalse(SelectionAPI.isDeclaredRejection(.notConnected))
    }
}

// MARK: - Selection store tests

final class SelectionStoreTests: XCTestCase, @unchecked Sendable {
    // MARK: Fixtures

    private static func agent(_ id: String, mode: String = "primary", hidden: Bool = false) -> AgentSummary {
        AgentSummary(info: AgentInfo(id: id, name: id.capitalized, mode: mode, hidden: hidden))
    }

    private static func model(_ id: String, _ provider: String, enabled: Bool = true) -> ModelSummary {
        ModelSummary(info: ModelInfo(id: id, providerID: provider, name: id, enabled: enabled, status: "active"))
    }

    @MainActor private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @MainActor private func makeStore(
        holder: SelectionSessionHolder = SelectionSessionHolder(SessionID(rawValue: "ses-1")),
        location: ActiveLocationProviding = SelectionFakeLocation(active: URL(fileURLWithPath: "/work")),
        sessionDirectory: (@MainActor () -> URL?)? = nil,
        connectionGeneration: (@MainActor () -> UInt64?)? = nil,
        listAgents: @escaping @Sendable (URL) async throws -> [AgentSummary] = { _ in [SelectionStoreTests.agent("build"), SelectionStoreTests.agent("plan")] },
        listModels: @escaping @Sendable (URL) async throws -> [ModelSummary] = { _ in [SelectionStoreTests.model("claude", "anthropic"), SelectionStoreTests.model("gpt", "openai")] },
        selectAgent: @escaping @Sendable (SessionID, String) async throws -> SelectionMutationOutcome = { _, agent in .applied(confirmed: SelectionConfirmation(agent: agent, model: nil)) },
        selectModel: @escaping @Sendable (SessionID, ModelRef) async throws -> SelectionMutationOutcome = { _, model in .applied(confirmed: SelectionConfirmation(agent: nil, model: model)) },
        readSelection: @escaping @Sendable (SessionID) async throws -> SelectionConfirmation = { _ in SelectionConfirmation(agent: nil, model: nil) }
    ) -> SelectionStore {
        SelectionStore(
            location: location,
            activeSessionID: { holder.id },
            activeSessionDirectory: sessionDirectory ?? { nil },
            connectionGeneration: connectionGeneration ?? { 0 },
            listAgents: listAgents,
            listModels: listModels,
            selectAgent: selectAgent,
            selectModel: selectModel,
            readSelection: readSelection
        )
    }

    // MARK: Discovery

    // 1. testDiscoverPublishesAgentsAndModels
    @MainActor func testDiscoverPublishesAgentsAndModels() async {
        let store = makeStore()
        store.discover()
        let loaded = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.primaryAgents.map(\.id), ["build", "plan"])
        XCTAssertEqual(store.selectableModels.map(\.id), ["anthropic/claude", "openai/gpt"])
    }

    // 2. testDiscoveryFailureIsTruthfulAndIndependent
    @MainActor func testDiscoveryFailureIsTruthfulAndIndependent() async {
        let store = makeStore(
            listAgents: { _ in throw SelectionAPIError.unauthorized },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] }
        )
        store.discover()
        let done = await waitUntil { store.agentDiscovery == .failed(.unauthorized) && store.modelDiscovery == .loaded }
        XCTAssertTrue(done)
        XCTAssertTrue(store.primaryAgents.isEmpty, "A failed agent discovery must not fabricate agents")
        XCTAssertEqual(store.selectableModels.count, 1)
    }

    // 3. testDiscoveryWithoutLocationFailsTruthfully
    @MainActor func testDiscoveryWithoutLocationFailsTruthfully() {
        let store = makeStore(location: SelectionFakeLocation(active: nil))
        store.discover()
        XCTAssertEqual(store.agentDiscovery, .failed(.noLocation))
        XCTAssertEqual(store.modelDiscovery, .failed(.noLocation))
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertTrue(store.models.isEmpty)
    }

    // 4. testDiscoveryEmptyIsLoadedButEmpty
    @MainActor func testDiscoveryEmptyIsLoadedButEmpty() async {
        let store = makeStore(listAgents: { _ in [] }, listModels: { _ in [] })
        store.discover()
        let done = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        XCTAssertTrue(done)
        XCTAssertTrue(store.primaryAgents.isEmpty)
        XCTAssertTrue(store.selectableModels.isEmpty)
    }

    // 5. testHiddenAndSubagentAreNotPrimary
    @MainActor func testHiddenAndSubagentAreNotPrimary() async {
        let store = makeStore(listAgents: { _ in [
            SelectionStoreTests.agent("build", mode: "primary"),
            SelectionStoreTests.agent("hidden", mode: "primary", hidden: true),
            SelectionStoreTests.agent("sub", mode: "subagent")
        ] })
        store.discover()
        let done = await waitUntil { store.agentDiscovery == .loaded }
        XCTAssertTrue(done)
        XCTAssertEqual(store.primaryAgents.map(\.id), ["build"])
    }

    // 6. testStaleAgentDiscoveryCannotRegressNewerDiscovery
    @MainActor func testStaleAgentDiscoveryCannotRegressNewerDiscovery() async {
        let gate = SelectionGate()
        let counter = SelectionCounter()
        let stale = [SelectionStoreTests.agent("stale")]
        let fresh = [SelectionStoreTests.agent("fresh")]
        let store = makeStore(listAgents: { _ in
            let n = await counter.increment()
            if n == 1 { await gate.enter() }
            return n == 1 ? stale : fresh
        })
        store.discover()
        await gate.waitUntilEntered()
        store.discover()
        let applied = await waitUntil { store.primaryAgents.map(\.id) == ["fresh"] }
        XCTAssertTrue(applied)
        await gate.releaseAndWait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.primaryAgents.map(\.id), ["fresh"], "A stale discovery response must not regress newer discovery")
    }

    // MARK: Independent selection

    // 7. testSelectAgentOnlyAppliedAfterBackendAccepts
    @MainActor func testSelectAgentOnlyAppliedAfterBackendAccepts() async {
        let gate = SelectionGate()
        let store = makeStore(selectAgent: { _, agent in
            await gate.enter()
            return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await gate.waitUntilEntered()
        XCTAssertNil(store.selectedAgent, "No optimistic success before the backend accepts")
        if case .inProgress(let agent) = store.agentSelection { XCTAssertEqual(agent, "build") } else { XCTFail("Expected inProgress") }
        await gate.releaseAndWait()
        let applied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(applied)
    }

    // 8. testSelectModelOnlyAppliedAfterBackendAccepts
    @MainActor func testSelectModelOnlyAppliedAfterBackendAccepts() async {
        let gate = SelectionGate()
        let store = makeStore(selectModel: { _, model in
            await gate.enter()
            return .applied(confirmed: SelectionConfirmation(agent: nil, model: model))
        })
        store.discover(); _ = await waitUntil { store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        await gate.waitUntilEntered()
        XCTAssertNil(store.selectedModel, "No optimistic success before the backend accepts")
        await gate.releaseAndWait()
        let applied = await waitUntil { store.selectedModel == ModelRef(id: "claude", providerID: "anthropic") && store.modelSelection == .idle }
        XCTAssertTrue(applied)
    }

    // 9. testAgentSwitchRetainsSelectedModel
    @MainActor func testAgentSwitchRetainsSelectedModel() async {
        let store = makeStore()
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "claude", providerID: "anthropic") }
        XCTAssertTrue(modelApplied)
        store.selectAgent("plan")
        let agentApplied = await waitUntil { store.selectedAgent == "plan" }
        XCTAssertTrue(agentApplied)
        XCTAssertEqual(store.selectedModel, ModelRef(id: "claude", providerID: "anthropic"), "Agent switch must retain a valid model")
    }

    // 10. testModelSwitchRetainsSelectedAgent
    @MainActor func testModelSwitchRetainsSelectedAgent() async {
        let store = makeStore()
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let agentApplied = await waitUntil { store.selectedAgent == "build" }
        XCTAssertTrue(agentApplied)
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") }
        XCTAssertTrue(modelApplied)
        XCTAssertEqual(store.selectedAgent, "build", "Model switch must retain the agent")
    }

    // 11. testSelectAgentRejectedIsTruthful
    @MainActor func testSelectAgentRejectedIsTruthful() async {
        let store = makeStore(selectAgent: { _, _ in .rejected(.backend(400)) })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let rejected = await waitUntil { store.agentSelection == .rejected(agent: "build", problem: .backend(400)) }
        XCTAssertTrue(rejected)
        XCTAssertNil(store.selectedAgent, "A rejected selection must not fabricate success")
    }

    // 12. testSelectModelUnknownIsTruthful
    @MainActor func testSelectModelUnknownIsTruthful() async {
        let store = makeStore(selectModel: { _, _ in .unknown(.requestFailed) })
        store.discover(); _ = await waitUntil { store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        let unknown = await waitUntil { store.modelSelection == .unknown(model: ModelRef(id: "claude", providerID: "anthropic"), problem: .requestFailed) }
        XCTAssertTrue(unknown)
        XCTAssertNil(store.selectedModel)
    }

    // 13. testSelectAgentNotDiscoveredIsRejectedWithoutCalling
    @MainActor func testSelectAgentNotDiscoveredIsRejectedWithoutCalling() async {
        let recorder = SelectionAgentRecorder()
        let store = makeStore(listAgents: { _ in [] }, selectAgent: { _, agent in await recorder.record(agent); return .applied(confirmed: nil) })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        XCTAssertEqual(store.agentSelection, .rejected(agent: "build", problem: .unavailable))
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
    }

    // 14. testDisabledModelIsNotSelectable
    @MainActor func testDisabledModelIsNotSelectable() async {
        let recorder = SelectionModelRecorder()
        let store = makeStore(
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic", enabled: false)] },
            selectModel: { _, model in await recorder.record(model); return .applied(confirmed: nil) }
        )
        store.discover(); _ = await waitUntil { store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        XCTAssertEqual(store.modelSelection, .rejected(model: ModelRef(id: "claude", providerID: "anthropic"), problem: .unavailable))
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
    }

    // 15. testSelectAgentWithoutActiveSessionIsRejected
    @MainActor func testSelectAgentWithoutActiveSessionIsRejected() async {
        let recorder = SelectionAgentRecorder()
        let store = makeStore(holder: SelectionSessionHolder(nil), selectAgent: { _, agent in await recorder.record(agent); return .applied(confirmed: nil) })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        XCTAssertEqual(store.agentSelection, .rejected(agent: "build", problem: .noSession))
        let count = await recorder.count()
        XCTAssertEqual(count, 0)
    }

    // 16. testSelectingCurrentAgentIsNoOp
    @MainActor func testSelectingCurrentAgentIsNoOp() async {
        let recorder = SelectionAgentRecorder()
        let store = makeStore(selectAgent: { _, agent in await recorder.record(agent); return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil)) })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        _ = await waitUntil { store.selectedAgent == "build" }
        store.selectAgent("build")
        let count = await recorder.count()
        XCTAssertEqual(count, 1, "Re-selecting the current agent should not call the backend again")
    }

    // MARK: Generations and session scope

    // 17. testStaleSelectionResponseCannotRegressNewerSelection
    @MainActor func testStaleSelectionResponseCannotRegressNewerSelection() async {
        let gate = SelectionGate()
        let store = makeStore(selectAgent: { _, agent in
            if agent == "build" { await gate.enter() }
            return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await gate.waitUntilEntered()
        store.selectAgent("plan")
        let applied = await waitUntil { store.selectedAgent == "plan" }
        XCTAssertTrue(applied)
        await gate.releaseAndWait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.selectedAgent, "plan", "A stale selection response must not regress a newer selection")
    }

    // 18. testSelectionNotAppliedToDifferentActiveSession
    @MainActor func testSelectionNotAppliedToDifferentActiveSession() async {
        let gate = SelectionGate()
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder, selectAgent: { _, agent in
            await gate.enter()
            return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await gate.waitUntilEntered()
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        await gate.releaseAndWait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertNil(store.selectedAgent, "A late selection for a previous session must not apply")
        XCTAssertEqual(store.agentSelection, .idle)
    }

    // 19. testLateSelectionWithoutSessionSyncIsDiscarded
    @MainActor func testLateSelectionWithoutSessionSyncIsDiscarded() async {
        let gate = SelectionGate()
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder, selectAgent: { _, agent in
            await gate.enter()
            return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await gate.waitUntilEntered()
        holder.id = SessionID(rawValue: "ses-B") // no activeSessionChanged()
        await gate.releaseAndWait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertNil(store.selectedAgent, "A completion for a different active session must be discarded")
        XCTAssertEqual(store.agentSelection, .idle)
    }

    // 20. testActiveSessionChangeResetsSelection
    @MainActor func testActiveSessionChangeResetsSelection() async {
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder)
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        _ = await waitUntil { store.selectedAgent == "build" }
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        _ = await waitUntil { store.selectedModel != nil }
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        XCTAssertNil(store.selectedAgent)
        XCTAssertNil(store.selectedModel)
        XCTAssertEqual(store.agentSelection, .idle)
        XCTAssertEqual(store.modelSelection, .idle)
    }

    // MARK: Reconciliation

    // 21. testCheckSelectionReconcilesUnknown
    @MainActor func testCheckSelectionReconcilesUnknown() async {
        let store = makeStore(
            selectAgent: { _, _ in .unknown(.requestFailed) },
            readSelection: { _ in SelectionConfirmation(agent: "build", model: nil) }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let unknown = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        XCTAssertTrue(unknown)
        store.checkSelection()
        let reconciled = await waitUntil { store.agentSelection == .idle && store.selectedAgent == "build" }
        XCTAssertTrue(reconciled, "A confirming read must clear the unknown selection")
    }

    // 22. testCheckSelectionDifferingReadStaysUnknown
    @MainActor func testCheckSelectionDifferingReadStaysUnknown() async {
        let store = makeStore(
            selectAgent: { _, _ in .unknown(.requestFailed) },
            readSelection: { _ in SelectionConfirmation(agent: "plan", model: nil) }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let unknown = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        XCTAssertTrue(unknown)
        store.checkSelection()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.agentSelection, .unknown(agent: "build", problem: .requestFailed), "A differing read cannot prove the requested selection")
        XCTAssertNil(store.selectedAgent)
    }

    // 23. testSessionChangeHydratesAuthoritativeSelection
    @MainActor func testSessionChangeHydratesAuthoritativeSelection() async {
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder, readSelection: { id in
            if id == SessionID(rawValue: "ses-B") {
                return SelectionConfirmation(agent: "plan", model: ModelRef(id: "gpt", providerID: "openai"))
            }
            return SelectionConfirmation(agent: nil, model: nil)
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        let hydrated = await waitUntil { store.selectedAgent == "plan" && store.selectedModel == ModelRef(id: "gpt", providerID: "openai") }
        XCTAssertTrue(hydrated, "Session change should hydrate the authoritative selection")
    }

    // 24. testSessionChangeReadFailureDoesNotFabricate
    @MainActor func testSessionChangeReadFailureDoesNotFabricate() async {
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder, readSelection: { id in
            if id == SessionID(rawValue: "ses-B") { throw SelectionAPIError.requestFailed }
            return SelectionConfirmation(agent: nil, model: nil)
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertNil(store.selectedAgent)
        XCTAssertNil(store.selectedModel)
    }

    // 25. testSelectionSupersedesPendingSessionHydration
    @MainActor func testSelectionSupersedesPendingSessionHydration() async {
        let gate = SelectionGate()
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let store = makeStore(holder: holder, selectAgent: { _, agent in
            .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        }, readSelection: { id in
            if id == SessionID(rawValue: "ses-B") {
                await gate.enter()
                return SelectionConfirmation(agent: "plan", model: nil)
            }
            return SelectionConfirmation(agent: nil, model: nil)
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        await gate.waitUntilEntered()
        // Session B needs its own catalog before dispatching a mutation;
        // hydration stays gated so this still tests selection supersession.
        store.discover()
        let catalogsLoaded = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        XCTAssertTrue(catalogsLoaded)
        store.selectAgent("build")
        let applied = await waitUntil { store.selectedAgent == "build" }
        XCTAssertTrue(applied)
        await gate.releaseAndWait()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.selectedAgent, "build", "A pending hydration must not overwrite a newer selection")
    }

    // 26. testRetryAfterRejectionReissuesSelection
    @MainActor func testRetryAfterRejectionReissuesSelection() async {
        let counter = SelectionCounter()
        let store = makeStore(selectAgent: { _, agent in
            let attempt = await counter.increment()
            if attempt == 1 { return .rejected(.serviceUnavailable) }
            return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let rejected = await waitUntil { store.agentSelection == .rejected(agent: "build", problem: .serviceUnavailable) }
        XCTAssertTrue(rejected)
        store.selectAgent("build") // explicit retry of the rejected value
        let applied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(applied, "Retrying a rejected selection must be able to succeed")
    }

    // 27. testCheckSelectionPublishesCheckingState
    @MainActor func testCheckSelectionPublishesCheckingState() async {
        let store = makeStore(
            selectAgent: { _, _ in .unknown(.requestFailed) },
            readSelection: { _ in SelectionConfirmation(agent: "build", model: nil) }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.selectAgent("build") // adopts the session without triggering hydration
        _ = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        store.checkSelection()
        XCTAssertTrue(store.isChecking, "Check must publish a busy state")
        let done = await waitUntil { !store.isChecking && store.agentSelection == .idle && store.selectedAgent == "build" }
        XCTAssertTrue(done)
    }

    // 28. testSessionHydrationFailureIsSurfacedAndRetryable
    @MainActor func testSessionHydrationFailureIsSurfacedAndRetryable() async {
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let counter = SelectionCounter()
        let store = makeStore(holder: holder, readSelection: { id in
            guard id == SessionID(rawValue: "ses-B") else { return SelectionConfirmation(agent: nil, model: nil) }
            let attempt = await counter.increment()
            if attempt == 1 { throw SelectionAPIError.requestFailed }
            return SelectionConfirmation(agent: "plan", model: nil)
        })
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        holder.id = SessionID(rawValue: "ses-B")
        store.activeSessionChanged()
        let surfaced = await waitUntil { store.hydrationProblem == .requestFailed }
        XCTAssertTrue(surfaced, "A failed hydration must be surfaced truthfully, not shown as an empty session")
        store.retryHydration()
        let hydrated = await waitUntil { store.selectedAgent == "plan" && store.hydrationProblem == nil }
        XCTAssertTrue(hydrated, "Retry must be able to hydrate the authoritative selection")
    }

    // 29. testAgentDelayedReadbackDoesNotClobberCompletedModel
    @MainActor func testAgentDelayedReadbackDoesNotClobberCompletedModel() async {
        // Agent mutation is delayed; model mutation completes first.
        // The agent readback carries a stale cross-axis model; the guard must
        // detect that a model mutation completed while the agent was in flight.
        let agentGate = SelectionGate()
        let store = makeStore(
            selectAgent: { _, agent in
                await agentGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: agent, model: ModelRef(id: "stale", providerID: "stale")))
            },
            selectModel: { _, model in
                .applied(confirmed: SelectionConfirmation(agent: nil, model: model))
            }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await agentGate.waitUntilEntered()
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        await agentGate.releaseAndWait()
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        XCTAssertEqual(store.selectedModel, ModelRef(id: "gpt", providerID: "openai"),
            "A delayed agent readback must not clobber a model adopted from a more recent model mutation")
    }

    // 30. testModelDelayedReadbackDoesNotClobberCompletedAgent
    @MainActor func testModelDelayedReadbackDoesNotClobberCompletedAgent() async {
        // Model mutation is delayed; agent mutation completes first.
        // The model readback carries a stale cross-axis agent; the guard must
        // detect that an agent mutation completed while the model was in flight.
        let modelGate = SelectionGate()
        let store = makeStore(
            selectAgent: { _, agent in
                .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
            },
            selectModel: { _, model in
                await modelGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: "stale-agent", model: model))
            }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        await modelGate.waitUntilEntered()
        store.selectAgent("build")
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        await modelGate.releaseAndWait()
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "claude", providerID: "anthropic") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        XCTAssertEqual(store.selectedAgent, "build",
            "A delayed model readback must not clobber an agent adopted from a more recent agent mutation")
    }

    // 31. testCrossAxisBothInFlightAgentCompletesFirstSafeReadbackAdopted
    @MainActor func testCrossAxisBothInFlightAgentCompletesFirstSafeReadbackAdopted() async {
        // Both agent and model mutations are in flight. The agent completes
        // first while the model is still pending. The agent readback carries
        // a cross-axis model that was sampled before the model mutation started;
        // the guard must detect this and not adopt the stale model. Then the
        // model completes and must not clobber the agent. Finally, a second
        // model mutation must safely adopt the agent from its readback (no
        // agent mutation in flight at that point).
        let modelGate = SelectionGate()
        let modelCounter = SelectionCounter()
        let store = makeStore(
            selectAgent: { _, agent in
                .applied(confirmed: SelectionConfirmation(agent: agent, model: ModelRef(id: "stale", providerID: "stale")))
            },
            selectModel: { _, model in
                let attempt = await modelCounter.increment()
                if attempt == 1 {
                    await modelGate.enter()
                    return .applied(confirmed: SelectionConfirmation(agent: "stale-agent", model: model))
                }
                // Second model mutation carries a cross-axis agent readback;
                // no agent mutation is in flight, so the guard must allow adoption.
                return .applied(confirmed: SelectionConfirmation(agent: "adopted-agent", model: model))
            }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        // Both mutations start; model gates.
        store.selectAgent("build")
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        await modelGate.waitUntilEntered()
        // Agent completes first; its model readback is stale (model mutation
        // started before the agent applied). The model is still in flight.
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        XCTAssertNil(store.selectedModel,
            "Agent completing first must not adopt a stale model readback while a model mutation is in flight")
        // Now release the first model mutation.
        await modelGate.releaseAndWait()
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        XCTAssertEqual(store.selectedAgent, "build",
            "First model completion must not clobber the agent")
        // A second model mutation with no agent mutation in flight must
        // safely adopt the agent from its cross-axis readback.
        store.selectModel(ModelRef(id: "claude", providerID: "anthropic"))
        let secondModel = await waitUntil { store.selectedModel == ModelRef(id: "claude", providerID: "anthropic") && store.modelSelection == .idle }
        XCTAssertTrue(secondModel)
        XCTAssertEqual(store.selectedAgent, "adopted-agent",
            "A model readback with no competing agent mutation must safely adopt the cross-axis agent")
    }

    // 32. testCrossAxisAgentStartsWhileModelInFlightDoesNotAdopt
    @MainActor func testCrossAxisAgentStartsWhileModelInFlightDoesNotAdopt() async {
        // Model is already in flight when the agent mutation starts, so the
        // agent readback sample is stale by construction and must not be
        // adopted even though no new model mutation starts afterwards.
        let modelGate = SelectionGate()
        let store = makeStore(
            selectAgent: { _, agent in
                .applied(confirmed: SelectionConfirmation(agent: agent, model: ModelRef(id: "stale", providerID: "stale")))
            },
            selectModel: { _, model in
                await modelGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: "stale-agent", model: model))
            }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        await modelGate.waitUntilEntered()
        store.selectAgent("build")
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        XCTAssertNil(store.selectedModel,
            "Agent starting while a model mutation is already in flight must not adopt its stale model readback")
        await modelGate.releaseAndWait()
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        XCTAssertEqual(store.selectedAgent, "build",
            "Delayed model readback must not clobber the agent adopted while it was in flight")
    }

    // 33. testCrossAxisModelStartsWhileAgentInFlightDoesNotAdopt
    @MainActor func testCrossAxisModelStartsWhileAgentInFlightDoesNotAdopt() async {
        // Mirror of 32: agent is already in flight when the model starts.
        let agentGate = SelectionGate()
        let store = makeStore(
            selectAgent: { _, agent in
                await agentGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: agent, model: ModelRef(id: "stale", providerID: "stale")))
            },
            selectModel: { _, model in
                .applied(confirmed: SelectionConfirmation(agent: "stale-agent", model: model))
            }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await agentGate.waitUntilEntered()
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        XCTAssertNil(store.selectedAgent,
            "Model starting while an agent mutation is already in flight must not adopt its stale agent readback")
        await agentGate.releaseAndWait()
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        XCTAssertEqual(store.selectedModel, ModelRef(id: "gpt", providerID: "openai"),
            "Delayed agent readback must not clobber the model adopted while it was in flight")
    }

    // 34. testCheckReconciledAgentSupersedesDelayedModelReadback
    @MainActor func testCheckReconciledAgentSupersedesDelayedModelReadback() async {
        // Agent mutation ends unknown; model starts while the unknown is
        // pending (its readback carries the pre-confirmation agent sample);
        // an explicit check confirms the agent; the delayed model readback
        // must not regress that reconciled value.
        let modelGate = SelectionGate()
        let store = makeStore(
            selectAgent: { _, _ in .unknown(.requestFailed) },
            selectModel: { _, model in
                await modelGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: "stale-agent", model: model))
            },
            readSelection: { _ in SelectionConfirmation(agent: "build", model: nil) }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let unknown = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        XCTAssertTrue(unknown)
        store.selectModel(ModelRef(id: "gpt", providerID: "openai"))
        await modelGate.waitUntilEntered()
        store.checkSelection()
        let reconciled = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(reconciled, "Explicit check must confirm the unknown agent")
        await modelGate.releaseAndWait()
        let modelApplied = await waitUntil { store.selectedModel == ModelRef(id: "gpt", providerID: "openai") && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        XCTAssertEqual(store.selectedAgent, "build",
            "A delayed model readback must not regress an agent value published by explicit reconciliation")
    }

    // MARK: Session/catalog/location invariant (H05b, SELECTION side only)

    // 35. testCheckReconciledModelSupersedesDelayedAgentReadback
    @MainActor func testCheckReconciledModelSupersedesDelayedAgentReadback() async {
        // Mirror of 34 in the opposite direction.
        let agentGate = SelectionGate()
        let wanted = ModelRef(id: "claude", providerID: "anthropic")
        let store = makeStore(
            selectAgent: { _, agent in
                await agentGate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: agent, model: ModelRef(id: "stale", providerID: "stale")))
            },
            selectModel: { _, _ in .unknown(.requestFailed) },
            readSelection: { _ in SelectionConfirmation(agent: nil, model: wanted) }
        )
        store.discover(); _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectModel(wanted)
        let unknown = await waitUntil { store.modelSelection == .unknown(model: wanted, problem: .requestFailed) }
        XCTAssertTrue(unknown)
        store.selectAgent("build")
        await agentGate.waitUntilEntered()
        store.checkSelection()
        let reconciled = await waitUntil { store.selectedModel == wanted && store.modelSelection == .idle }
        XCTAssertTrue(reconciled, "Explicit check must confirm the unknown model")
        await agentGate.releaseAndWait()
        let agentApplied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentApplied)
        XCTAssertEqual(store.selectedModel, wanted,
            "A delayed agent readback must not regress a model value published by explicit reconciliation")
    }

    // 36. testPinnedSessionIgnoresFolderChangesRetainsCatalogsA
    @MainActor func testPinnedSessionIgnoresFolderChangesRetainsCatalogsA() async {
        let dirA = URL(fileURLWithPath: "/A")
        let dirB = URL(fileURLWithPath: "/B")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let location = SelectionFakeLocation(active: dirA)
        let requested = SelectionDirectoryRecorder()
        let store = makeStore(
            holder: holder,
            location: location,
            sessionDirectory: { () -> URL? in dirA },
            listAgents: { dir in await requested.record(dir); return [SelectionStoreTests.agent("a-agent")] },
            listModels: { dir in await requested.record(dir); return [SelectionStoreTests.model("m", "p")] }
        )
        store.discover()
        let loaded = await waitUntil { store.agentDiscovery == .loaded && store.catalogDirectory == dirA }
        XCTAssertTrue(loaded)
        // Chosen folder moves while session A is pinned: without rediscovery
        // the store must retain catalogs A.
        location.activeLocation = ResolvedLocation(directory: dirB, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: dirB, canonical: dirB))
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.catalogDirectory, dirA, "Folder changes while pinned must retain catalogs A")
        XCTAssertEqual(store.primaryAgents.map(\.id), ["a-agent"])
        // Even an explicit rediscovery while pinned must scope to the
        // authoritative session directory A, never the fallback folder B.
        await requested.reset()
        store.discover()
        let reloaded = await waitUntil { store.agentDiscovery == .loaded && store.catalogDirectory == dirA }
        XCTAssertTrue(reloaded)
        let dirs = await requested.values()
        XCTAssertFalse(dirs.isEmpty)
        XCTAssertTrue(dirs.allSatisfy { $0 == dirA }, "Catalog discovery while pinned must query session directory A, got \(dirs)")
    }

    // 37. testSessionChangeRescopesCatalogToBStaleACannotPublish
    @MainActor func testSessionChangeRescopesCatalogToBStaleACannotPublish() async {
        let dirA = URL(fileURLWithPath: "/A")
        let dirB = URL(fileURLWithPath: "/B")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let dirHolder = SelectionDirHolder(dirA)
        let gate = SelectionGate()
        let counter = SelectionCounter()
        let location = SelectionFakeLocation(active: dirA)
        let store = makeStore(
            holder: holder,
            location: location,
            sessionDirectory: { () -> URL? in dirHolder.directory },
            listAgents: { _ in
                let n = await counter.increment()
                if n == 1 { await gate.enter() }
                return n == 1 ? [SelectionStoreTests.agent("stale-A")] : [SelectionStoreTests.agent("fresh-B")]
            },
            listModels: { _ in [SelectionStoreTests.model("m", "p")] }
        )
        store.discover()
        await gate.waitUntilEntered()
        // Load session B (authoritative directory B) and rediscover.
        holder.id = SessionID(rawValue: "ses-B")
        dirHolder.directory = dirB
        store.activeSessionChanged()
        store.discover()
        let fresh = await waitUntil { store.primaryAgents.map(\.id) == ["fresh-B"] && store.catalogDirectory == dirB }
        XCTAssertTrue(fresh, "Session B must scope catalogs to directory B")
        await gate.releaseAndWait()
        for _ in 0..<20 { await MainActor.run {} }
        XCTAssertEqual(store.primaryAgents.map(\.id), ["fresh-B"], "Delayed catalogs for A must not publish over B")
        XCTAssertEqual(store.catalogDirectory, dirB)
    }

    // 38. testMutationBlockedUntilMatchingCatalogsLoaded
    @MainActor func testMutationBlockedUntilMatchingCatalogsLoaded() async {
        let dirA = URL(fileURLWithPath: "/A")
        let dirB = URL(fileURLWithPath: "/B")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let dirHolder = SelectionDirHolder(dirA)
        let recorder = SelectionAgentRecorder()
        let location = SelectionFakeLocation(active: dirA)
        let store = makeStore(
            holder: holder,
            location: location,
            sessionDirectory: { () -> URL? in dirHolder.directory },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] },
            selectAgent: { _, agent in await recorder.record(agent); return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil)) }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.catalogDirectory == dirA }
        store.activeSessionChanged()
        // Move to session B / directory B without rediscovery: the mutation
        // must be rejected as unavailable, never sent from catalog A.
        holder.id = SessionID(rawValue: "ses-B")
        dirHolder.directory = dirB
        store.activeSessionChanged()
        store.selectAgent("build")
        XCTAssertEqual(store.agentSelection, .rejected(agent: "build", problem: .unavailable))
        let countBeforeCatalog = await recorder.count()
        XCTAssertEqual(countBeforeCatalog, 0, "No mutation may be sent from stale catalog A for session B")
        // After matching catalogs for B load, the same mutation may proceed.
        store.discover()
        let loadedB = await waitUntil { store.catalogDirectory == dirB && store.agentDiscovery == .loaded }
        XCTAssertTrue(loadedB)
        store.selectAgent("build")
        let applied = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(applied)
        let countAfterCatalog = await recorder.count()
        XCTAssertEqual(countAfterCatalog, 1)
    }

    // 39. testConnectionReplacementDiscardsOldMutationReplyAsUnknown
    @MainActor func testConnectionReplacementDiscardsOldMutationReplyAsUnknown() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let gate = SelectionGate()
        let recorder = SelectionAgentRecorder()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] },
            selectAgent: { _, agent in
                await recorder.record(agent)
                await gate.enter()
                return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
            }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        await gate.waitUntilEntered()
        conn.generation = 2 // connection replaced while the mutation was sent
        await gate.releaseAndWait()
        let qualified = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .notConnected) }
        XCTAssertTrue(qualified, "An old-context reply must not confirm; it qualifies unknown")
        XCTAssertNil(store.selectedAgent, "An old-context reply must never publish a selection")
        let sendCount = await recorder.count()
        XCTAssertEqual(sendCount, 1, "No blind retry after connection replacement")
    }

    // 40. testDisconnectedDiscoverFailsWithoutTransport
    @MainActor func testDisconnectedDiscoverFailsWithoutTransport() async {
        let conn = SelectionConnHolder(nil)
        let requested = SelectionDirectoryRecorder()
        let store = makeStore(
            location: SelectionFakeLocation(active: URL(fileURLWithPath: "/A")),
            sessionDirectory: { () -> URL? in URL(fileURLWithPath: "/A") },
            connectionGeneration: { conn.generation },
            listAgents: { dir in await requested.record(dir); return [SelectionStoreTests.agent("build")] },
            listModels: { dir in await requested.record(dir); return [SelectionStoreTests.model("m", "p")] }
        )
        store.discover()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.agentDiscovery, .failed(.notConnected))
        XCTAssertEqual(store.modelDiscovery, .failed(.notConnected))
        XCTAssertNil(store.catalogDirectory)
        let requestedDirectories = await requested.values()
        XCTAssertTrue(requestedDirectories.isEmpty, "No transport-backed list action may run while disconnected")
    }

    // MARK: Review fixes (binding ownership, reconnect hydration, staleness)

    // 41. testBindOwnsDiscoveryWithoutViewAndDedupesTitleOnlyUpdate
    @MainActor func testBindOwnsDiscoveryWithoutViewAndDedupesTitleOnlyUpdate() async {
        let dirA = URL(fileURLWithPath: "/A")
        let dirB = URL(fileURLWithPath: "/B")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-H05b-\(UUID().uuidString)")
        let prefs = LocalPreferencesStore(baseDirectory: base)
        let location = SelectionFakeLocation(active: dirA)
        let rootsBox = SelectionRootsBox()
        let sessionStore = ActiveSessionStore(
            preferences: prefs,
            location: location,
            list: { _ in await rootsBox.page() },
            get: { id in
                let dir = id.rawValue == "ses-B" ? dirB : dirA
                return SessionSummary(info: SessionInfo(id: id.rawValue, parentID: nil, projectID: "p", title: "One", location: LocationRef(directory: dir.path)))
            },
            create: { _ in throw SessionAPIError.requestFailed }
        )
        let owner = ServiceConnectionOwner(discover: { () async throws -> LocalServiceConnection in throw ServiceDiscoveryError.registrationMissing })
        let requested = SelectionDirectoryRecorder()
        let selection = SelectionStore(
            location: location,
            activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id },
            activeSessionDirectory: { [weak sessionStore] in sessionStore?.activeSession?.directory },
            connectionGeneration: { () -> UInt64? in 1 },
            listAgents: { dir in await requested.record(dir); return [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("m", "p")] },
            selectAgent: { _, agent in .applied(confirmed: SelectionConfirmation(agent: agent, model: nil)) },
            selectModel: { _, model in .applied(confirmed: SelectionConfirmation(agent: nil, model: model)) },
            readSelection: { _ in SelectionConfirmation(agent: nil, model: nil) }
        )
        selection.bind(sessionStore: sessionStore, connectionOwner: owner, location: location)
        // No view is mounted: driving the session store alone must discover.
        sessionStore.load(SessionID(rawValue: "ses-A"))
        let loadedA = await waitUntil { selection.catalogDirectory == dirA && selection.agentDiscovery == .loaded }
        XCTAssertTrue(loadedA, "Store-owned binding must discover without a mounted view")
        await requested.reset()
        // Title-only authoritative update via roots refresh (no loading flap):
        // same id + directory must not cause a duplicate discover.
        await rootsBox.set([SessionSummary(info: SessionInfo(id: "ses-A", parentID: nil, projectID: "p", title: "Renamed", location: LocationRef(directory: dirA.path)))])
        sessionStore.refreshRoots()
        let renamed = await waitUntil { sessionStore.activeSession?.title == "Renamed" }
        XCTAssertTrue(renamed, "Title-only update must land")
        for _ in 0..<20 { await MainActor.run {} }
        let titleUpdateRequests = await requested.values()
        XCTAssertTrue(titleUpdateRequests.isEmpty, "Title-only update must not re-discover")
        XCTAssertEqual(selection.catalogDirectory, dirA)
        // A genuine scope change still re-discovers through the binding.
        sessionStore.load(SessionID(rawValue: "ses-B"))
        let loadedB = await waitUntil { selection.catalogDirectory == dirB && selection.agentDiscovery == .loaded }
        XCTAssertTrue(loadedB, "Session change must re-scope catalogs through the binding")
    }

    // 42. testOldConnectionHydrationCannotPublish
    @MainActor func testOldConnectionHydrationCannotPublish() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let gate = SelectionGate()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            readSelection: { _ in
                await gate.enter()
                return SelectionConfirmation(agent: "plan", model: nil)
            }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged() // hydration starts on conn 1, gated
        conn.generation = 2 // reconnect before the old read returns
        await gate.releaseAndWait()
        for _ in 0..<20 { await MainActor.run {} }
        XCTAssertNil(store.selectedAgent, "Old-connection hydration must never publish")
        XCTAssertNil(store.selectionConnection)
        XCTAssertFalse(store.isSelectionCurrent)
        XCTAssertFalse(store.isHydrating)
    }

    // 43. testReconnectSameSessionHydratesWithoutClearingUnknown
    @MainActor func testReconnectSameSessionHydratesWithoutClearingUnknown() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let modelRecorder = SelectionModelRecorder()
        let wanted = ModelRef(id: "claude", providerID: "anthropic")
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] },
            selectModel: { _, model in await modelRecorder.record(model); return .unknown(.requestFailed) },
            readSelection: { _ in SelectionConfirmation(agent: "fresh", model: nil) }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        let hydrated = await waitUntil { store.selectedAgent == "fresh" && store.isSelectionCurrent }
        XCTAssertTrue(hydrated)
        XCTAssertEqual(store.selectionConnection, 1)
        // Same-session reconnect: retained values read stale until confirmed.
        conn.generation = 2
        store.connectionChanged()
        XCTAssertNil(store.selectionConnection, "Reconnect must invalidate selection currency")
        XCTAssertFalse(store.isSelectionCurrent)
        let rehydrated = await waitUntil { store.selectedAgent == "fresh" && store.selectionConnection == 2 && store.isSelectionCurrent && store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        XCTAssertTrue(rehydrated, "Reconnect must start a new authoritative read when ready")
        // Unknown mutation state survives a reconnect: no clearing, no retry.
        store.selectModel(wanted)
        let unknown = await waitUntil { store.modelSelection == .unknown(model: wanted, problem: .requestFailed) }
        XCTAssertTrue(unknown)
        conn.generation = 3
        store.connectionChanged()
        for _ in 0..<20 { await MainActor.run {} }
        XCTAssertEqual(store.modelSelection, .unknown(model: wanted, problem: .requestFailed), "Reconnect must not clear unknown mutation")
        let mutationCount = await modelRecorder.count()
        XCTAssertEqual(mutationCount, 1, "Reconnect must not blind-retry")
        XCTAssertEqual(store.selectedAgent, "fresh", "Reconnect must not clear retained values either")
    }

    // 44. testCancelledMutationQualifiesUnknownSameContext
    @MainActor func testCancelledMutationQualifiesUnknownSameContext() async {
        let store = makeStore(
            selectAgent: { _, _ in throw CancellationError() }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded }
        store.activeSessionChanged()
        store.selectAgent("build")
        let qualified = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        XCTAssertTrue(qualified, "A cancelled-after-dispatch mutation with intact context must qualify unknown, not idle")
        XCTAssertNil(store.selectedAgent, "A lost reply must never confirm")
    }

    // 45. testDiscoverBeforeConnectionChangedCannotSwallowReconnectHydration
    @MainActor func testDiscoverBeforeConnectionChangedCannotSwallowReconnectHydration() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let reads = SelectionCounter()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            readSelection: { _ in
                _ = await reads.increment()
                return SelectionConfirmation(agent: "fresh", model: nil)
            }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        let current = await waitUntil { store.selectionConnection == 1 && store.isSelectionCurrent }
        XCTAssertTrue(current)
        let readsAfterFirst = await reads.current()
        // Same-turn reconnect where a session/folder refresh wins the race and
        // re-keys discovery first: hydration must still reset and re-read.
        conn.generation = 2
        store.discover()
        store.connectionChanged()
        let rehydrated = await waitUntil { store.selectionConnection == 2 && store.isSelectionCurrent }
        XCTAssertTrue(rehydrated, "A pre-refresh discover must not swallow reconnect hydration")
        let totalReads = await reads.current()
        XCTAssertGreaterThanOrEqual(totalReads, readsAfterFirst + 1, "Reconnect must start a fresh authoritative read")
    }

    // 46. testSingleAxisReconnectCannotBlessStaleOtherAxis
    @MainActor func testSingleAxisReconnectCannotBlessStaleOtherAxis() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let agentAttempts = SelectionCounter()
        let oldModel = ModelRef(id: "old", providerID: "p")
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("old", "p"), SelectionStoreTests.model("new", "p")] },
            selectAgent: { _, agent in
                let n = await agentAttempts.increment()
                if n == 1 { return .unknown(.requestFailed) }
                return .applied(confirmed: SelectionConfirmation(agent: agent, model: nil))
            },
            selectModel: { _, model in .applied(confirmed: SelectionConfirmation(agent: nil, model: model)) },
            readSelection: { _ in SelectionConfirmation(agent: nil, model: nil) }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        // Publish the old model on conn1, then leave the agent unknown.
        store.selectModel(oldModel)
        let modelApplied = await waitUntil { store.selectedModel == oldModel && store.modelSelection == .idle }
        XCTAssertTrue(modelApplied)
        store.selectAgent("build")
        let unknown = await waitUntil { store.agentSelection == .unknown(agent: "build", problem: .requestFailed) }
        XCTAssertTrue(unknown)
        // Same-session reconnect invalidates both axes; the pending unknown
        // owns hydration (no auto read), so rediscover then confirm the agent
        // alone on conn2. The retained old model must stay stale.
        conn.generation = 2
        store.connectionChanged()
        let rediscovered = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        XCTAssertTrue(rediscovered)
        store.selectAgent("build")
        let agentConfirmed = await waitUntil { store.selectedAgent == "build" && store.agentSelection == .idle }
        XCTAssertTrue(agentConfirmed)
        XCTAssertEqual(store.selectedModel, oldModel, "Single-axis apply must retain the old model value")
        XCTAssertFalse(store.isSelectionCurrent, "A conn2 agent apply must not bless a retained conn1 model as current")
        XCTAssertEqual(store.selectionSessionID, SessionID(rawValue: "ses-A"))
    }

    // MARK: Reviewer fixes (hydration gate, currency clear, resolving)

    // 47. testRejectedDisconnectReconnectRehydratesWithoutResend
    @MainActor func testRejectedDisconnectReconnectRehydratesWithoutResend() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let agentRecorder = SelectionAgentRecorder()
        let reads = SelectionCounter()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] },
            selectAgent: { _, agent in
                await agentRecorder.record(agent)
                return .rejected(.serviceUnavailable)
            },
            readSelection: { _ in
                _ = await reads.increment()
                return SelectionConfirmation(agent: "fresh", model: ModelRef(id: "claude", providerID: "anthropic"))
            }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged()
        let hydrated = await waitUntil { store.selectedAgent == "fresh" && store.isSelectionCurrent }
        XCTAssertTrue(hydrated)
        let readsAfterFirst = await reads.current()
        // A settled rejection must not block later hydration.
        store.selectAgent("build")
        let rejected = await waitUntil { store.agentSelection == .rejected(agent: "build", problem: .serviceUnavailable) }
        XCTAssertTrue(rejected)
        // Disconnect: currency invalidated, truthful problem surfaced.
        conn.generation = nil
        store.connectionChanged()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertNil(store.selectionConnection)
        XCTAssertFalse(store.isSelectionCurrent)
        // Reconnect: authoritative rehydration must run despite the settled
        // rejection, without resending the rejected mutation.
        conn.generation = 2
        store.connectionChanged()
        let rehydrated = await waitUntil { store.selectionConnection == 2 && store.isSelectionCurrent }
        XCTAssertTrue(rehydrated, "Reconnect must hydrate authoritatively despite a settled rejection")
        XCTAssertEqual(store.selectedAgent, "fresh")
        XCTAssertEqual(store.agentSelection, .rejected(agent: "build", problem: .serviceUnavailable), "Rehydration must preserve the rejected attempt")
        let agentSends = await agentRecorder.count()
        XCTAssertEqual(agentSends, 1, "Reconnect must not resend the rejected mutation")
        let totalReads = await reads.current()
        XCTAssertGreaterThanOrEqual(totalReads, readsAfterFirst + 1)
    }

    // 48. testRetryHydrationAfterReadFailureWithRejectedWorks
    @MainActor func testRetryHydrationAfterReadFailureWithRejectedWorks() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let reads = SelectionCounter()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { _ in [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("claude", "anthropic")] },
            selectAgent: { _, _ in .rejected(.serviceUnavailable) },
            readSelection: { _ in
                let n = await reads.increment()
                if n == 1 { throw SelectionAPIError.requestFailed }
                return SelectionConfirmation(agent: "fresh", model: nil)
            }
        )
        store.discover()
        _ = await waitUntil { store.agentDiscovery == .loaded && store.modelDiscovery == .loaded }
        store.activeSessionChanged() // first read fails
        let surfaced = await waitUntil { store.hydrationProblem == .requestFailed && !store.isHydrating }
        XCTAssertTrue(surfaced)
        // Settle one axis as rejected; retry must still re-read authority.
        store.selectAgent("build")
        let rejected = await waitUntil { store.agentSelection == .rejected(agent: "build", problem: .serviceUnavailable) }
        XCTAssertTrue(rejected)
        store.retryHydration()
        let hydrated = await waitUntil { store.selectedAgent == "fresh" && store.hydrationProblem == nil && !store.isHydrating }
        XCTAssertTrue(hydrated, "Retry must hydrate after a read failure even with a settled rejection")
        XCTAssertEqual(store.agentSelection, .rejected(agent: "build", problem: .serviceUnavailable))
    }

    // 49. testPreloadedDisconnectClearsCatalogCurrency
    @MainActor func testPreloadedDisconnectClearsCatalogCurrency() async {
        let dirA = URL(fileURLWithPath: "/A")
        let holder = SelectionSessionHolder(SessionID(rawValue: "ses-A"))
        let conn = SelectionConnHolder(1)
        let requested = SelectionDirectoryRecorder()
        let store = makeStore(
            holder: holder,
            location: SelectionFakeLocation(active: dirA),
            sessionDirectory: { () -> URL? in dirA },
            connectionGeneration: { conn.generation },
            listAgents: { dir in await requested.record(dir); return [SelectionStoreTests.agent("build")] },
            listModels: { dir in await requested.record(dir); return [SelectionStoreTests.model("m", "p")] }
        )
        store.discover()
        let loaded = await waitUntil { store.agentDiscovery == .loaded && store.catalogDirectory == dirA }
        XCTAssertTrue(loaded)
        // Disconnect must clear catalog currency so no stale directory shows.
        conn.generation = nil
        store.discover()
        for _ in 0..<10 { await MainActor.run {} }
        XCTAssertEqual(store.agentDiscovery, .failed(.notConnected))
        XCTAssertEqual(store.modelDiscovery, .failed(.notConnected))
        XCTAssertTrue(store.agents.isEmpty)
        XCTAssertTrue(store.models.isEmpty)
        XCTAssertNil(store.catalogDirectory, "Disconnect must not leave a stale catalog directory")
        let requestedAfterDisconnect = await requested.values()
        // Only the pre-disconnect loads ran; the disconnected discover sends nothing.
        XCTAssertEqual(requestedAfterDisconnect.count, 2)
    }

    // 50. testSameFolderResolvingDoesNotClearCatalogs
    @MainActor func testSameFolderResolvingDoesNotClearCatalogs() async {
        let dir = URL(fileURLWithPath: "/A")
        let gate = SelectionGate()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Joycode-Resolving-\(UUID().uuidString)")
        let prefs = LocalPreferencesStore(baseDirectory: base)
        let resolve: @Sendable (URL) async throws -> ResolvedLocation = { directory in
            await gate.enter()
            return ResolvedLocation(directory: directory, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: directory, canonical: directory))
        }
        let locationStore = ActiveLocationStore(preferences: prefs, availability: { _ in .directory }, resolve: resolve)
        let rootsBox = SelectionRootsBox()
        let sessionStore = ActiveSessionStore(
            preferences: prefs,
            location: locationStore,
            list: { _ in await rootsBox.page() },
            get: { id in SessionSummary(info: SessionInfo(id: id.rawValue, parentID: nil, projectID: "p", title: "T", location: LocationRef(directory: dir.path))) },
            create: { _ in throw SessionAPIError.requestFailed }
        )
        let owner = ServiceConnectionOwner(discover: { () async throws -> LocalServiceConnection in throw ServiceDiscoveryError.registrationMissing })
        let requested = SelectionDirectoryRecorder()
        let selection = SelectionStore(
            location: locationStore,
            activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id },
            activeSessionDirectory: { [weak sessionStore] in sessionStore?.activeSession?.directory },
            connectionGeneration: { () -> UInt64? in 1 },
            listAgents: { d in await requested.record(d); return [SelectionStoreTests.agent("build")] },
            listModels: { _ in [SelectionStoreTests.model("m", "p")] },
            selectAgent: { _, agent in .applied(confirmed: SelectionConfirmation(agent: agent, model: nil)) },
            selectModel: { _, model in .applied(confirmed: SelectionConfirmation(agent: nil, model: model)) },
            readSelection: { _ in SelectionConfirmation(agent: nil, model: nil) }
        )
        selection.bind(sessionStore: sessionStore, connectionOwner: owner, location: locationStore)
        // Initial resolve for the chosen folder.
        locationStore.select(dir)
        await gate.waitUntilEntered()
        await gate.releaseAndWait()
        let loaded = await waitUntil { selection.catalogDirectory == dir && selection.agentDiscovery == .loaded }
        XCTAssertTrue(loaded, "Fallback discovery must load catalogs for the resolved folder")
        // Re-verify the same folder: the transient resolving state must not
        // clear catalogs before the authoritative resolved key lands.
        await requested.reset()
        locationStore.select(dir)
        await gate.waitUntilEntered()
        for _ in 0..<20 { await MainActor.run {} }
        XCTAssertEqual(selection.catalogDirectory, dir, "Same-folder resolving must not clear catalogs")
        XCTAssertEqual(selection.agentDiscovery, .loaded)
        XCTAssertFalse(selection.primaryAgents.isEmpty)
        await gate.releaseAndWait()
        let settled = await waitUntil { selection.catalogDirectory == dir && selection.agentDiscovery == .loaded }
        XCTAssertTrue(settled)
        let rediscoveryDirs = await requested.values()
        XCTAssertTrue(rediscoveryDirs.isEmpty, "Same-folder re-resolution must not duplicate discovery transport")
    }
}

// MARK: - Shared test helpers

@MainActor private final class SelectionSessionHolder {
    var id: SessionID?
    init(_ id: SessionID?) { self.id = id }
}

@MainActor private final class SelectionDirHolder {
    var directory: URL?
    init(_ directory: URL?) { self.directory = directory }
}

@MainActor private final class SelectionConnHolder {
    var generation: UInt64?
    init(_ generation: UInt64?) { self.generation = generation }
}

private actor SelectionDirectoryRecorder {
    private var dirs: [URL] = []
    func record(_ dir: URL) { dirs.append(dir) }
    func values() -> [URL] { dirs }
    func reset() { dirs.removeAll() }
}

private actor SelectionRootsBox {
    private var sessions: [SessionSummary] = []
    func set(_ sessions: [SessionSummary]) { self.sessions = sessions }
    func page() -> SessionPage { SessionPage(sessions: sessions, nextCursor: nil, previousCursor: nil) }
}

@MainActor private final class SelectionFakeLocation: ActiveLocationProviding {
    var activeLocation: ResolvedLocation?
    init(active: URL? = nil) {
        if let active {
            activeLocation = ResolvedLocation(directory: active, project: ProjectIdentity(id: ProjectID(rawValue: "p"), directory: active, canonical: active))
        }
    }
}

private struct SelectionCredentials: CredentialCapability {
    var safeDescription: String { "selection-test" }
    func credential(for connection: ConnectionID) async throws -> ServiceCredential? { nil }
}

private actor SelectionTestTransport: HTTPTransport {
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

private actor SelectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    func enter() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        entered = false
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
    func releaseAndWait() async {
        release()
        while entered { await Task.yield() }
    }
}

private actor SelectionCounter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
    func current() -> Int { value }
}

private actor SelectionAgentRecorder {
    private var agents: [String] = []
    func record(_ agent: String) { agents.append(agent) }
    func count() -> Int { agents.count }
}

private actor SelectionModelRecorder {
    private var models: [ModelRef] = []
    func record(_ model: ModelRef) { models.append(model) }
    func count() -> Int { models.count }
}
