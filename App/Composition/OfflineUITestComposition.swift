import Combine
import Foundation

#if DEBUG
/// DEBUG-only offline UI fixture for H04/H05 interaction coverage.
///
/// Enabled only by the explicit `--joycode-offline-ui-fixture` launch
/// argument. Release builds cannot enable it: this type does not exist there
/// and `isEnabled` is only consulted under `#if DEBUG` in `JoycodeApp`.
///
/// The fixture is fully local and deterministic:
/// - Diagnostic model stays disconnected with an inert discover closure.
/// - Preferences live in a unique temporary directory, never the production
///   Application Support path.
/// - Sessions, rename, create, agent/model discovery, selection, and pending
///   permission approvals all run against an in-memory backend. No network,
///   discovery, registration, or provider calls are issued.
///
/// Labels are realistic but fixture-scoped ("/fixture", "Fixture Session A/B").
enum OfflineUITestComposition {
    static let launchArgument = "--joycode-offline-ui-fixture"
    @MainActor private static var executionSequence = 0

    static var isEnabled: Bool {
        CommandLine.arguments.contains(launchArgument)
    }

    @MainActor static func build() -> (
        model: DiagnosticModel,
        eventOwner: ConnectionEventOwner,
        pickerModel: ProjectPickerModel,
        sessionStore: ActiveSessionStore,
        selectionStore: SelectionStore,
        composerStore: ComposerStore,
        transcriptStore: TranscriptStore,
        executionStore: ExecutionStatusStore,
        permissionStore: PermissionStore
    ) {
        let backend = OfflineFixtureBackend()
        let fixtureDirectory = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let project = ProjectIdentity(
            id: ProjectID(rawValue: "fixture-project"),
            directory: fixtureDirectory,
            canonical: fixtureDirectory
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Joycode-OfflineUITest-\(UUID().uuidString)", isDirectory: true)
        let preferences = LocalPreferencesStore(baseDirectory: base)
        var seeded = LocalPreferences(selectedDirectory: fixtureDirectory)
        seeded.lastSessionID = SessionID(rawValue: "ses-fixture-a")
        try? preferences.save(seeded)

        // Disconnected and inert: never resolves registration or probes a server.
        let model = DiagnosticModel(discover: {
            throw ServiceDiscoveryError.registrationMissing
        })
        let eventOwner = ConnectionEventOwner(connectionOwner: model, source: OfflineInertEventSource())

        let locationStore = ActiveLocationStore(
            preferences: preferences,
            availability: { _ in .directory },
            resolve: { _ in ResolvedLocation(directory: fixtureDirectory, project: project) }
        )
        let pickerModel = ProjectPickerModel(store: locationStore)

        let sessionStore = ActiveSessionStore(
            preferences: preferences,
            location: locationStore,
            list: { _ in await backend.list() },
            get: { id in try await backend.get(id) },
            create: { request in await backend.create(request, directory: fixtureDirectory) },
            rename: { id, title in await backend.rename(id, title: title) },
            connectionReady: { true },
            connectionGeneration: { 1 }
        )
        // Same ownership as production composition: retry a pending restore on
        // a new connection generation and refresh the browsed root list when
        // the chosen folder changes. All requests stay inside the fixture.
        sessionStore.connectionSubscription = model.$currentContext
            .receive(on: DispatchQueue.main)
            .sink { [weak sessionStore] context in
                Task { @MainActor [weak sessionStore] in sessionStore?.noteConnectionContext(context?.generation) }
            }
        sessionStore.noteConnectionContext(model.currentContext?.generation)
        sessionStore.locationSubscription = locationStore.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak sessionStore] _ in
                Task { @MainActor [weak sessionStore] in sessionStore?.noteBrowsingDirectoryChanged() }
            }

        let selectionStore = SelectionStore(
            location: locationStore,
            activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id },
            activeSessionDirectory: { [weak sessionStore] in sessionStore?.activeSession?.directory },
            connectionGeneration: { 1 },
            listAgents: { _ in await backend.agents() },
            listModels: { _ in await backend.models() },
            selectAgent: { id, agent in await backend.selectAgent(id, agent: agent) },
            selectModel: { id, model in await backend.selectModel(id, model: model) },
            readSelection: { id in await backend.readSelection(id) }
        )
        selectionStore.bind(sessionStore: sessionStore, connectionOwner: model, location: locationStore)

        let composer = ComposerStore(context: { [weak sessionStore, weak selectionStore] in
            ComposerContext(sessionID: sessionStore?.activeSession?.id, directory: sessionStore?.activeSession?.directory, connectionGeneration: 1, isReady: selectionStore?.isSelectionCurrent == true && selectionStore?.selectedAgent != nil && selectionStore?.selectedModel != nil)
        }, send: { @MainActor request in
            let result = await backend.accept(request)
            // Stands in for the server's durable `session.inbox.delivered`
            // publication so the transcript refreshes without a manual click.
            if case .admitted = result {
                OfflineUITestComposition.deliverInboxDelivered(sessionID: request.sessionID, to: eventOwner.fanout)
                OfflineUITestComposition.deliverExecution("started", sessionID: request.sessionID, to: eventOwner.fanout)
            }
            return result
        })
        composer.bind(sessionStore: sessionStore, selectionStore: selectionStore, connectionOwner: model)
        let transcript = TranscriptStore(activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id }, connectionGeneration: { 1 }, awaitsEventStream: true, load: { id, _ in await backend.history(id) })
        ConversationComposition.bindTranscript(transcript, sessions: sessionStore, connectionOwner: model)
        // The disconnected model has no real stream; the fixture plays the
        // readiness marker through the same fanout production uses.
        eventOwner.fanout.reset(generation: 1)
        ConversationComposition.bindTranscriptEvents(transcript, fanout: eventOwner.fanout)
        let execution = ExecutionStatusStore(activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id }, connectionGeneration: { 1 }, loadActive: { await backend.activeSessions() }, interrupt: { id in
            let accepted = await backend.interrupt(id)
            if accepted {
                OfflineUITestComposition.deliverExecution("interrupted", sessionID: id, to: eventOwner.fanout)
            }
            return accepted ? .accepted : .notInterrupted
        })
        ConversationComposition.bindExecution(execution, sessions: sessionStore, connectionOwner: model)
        ConversationComposition.bindExecutionEvents(execution, fanout: eventOwner.fanout)
        let permission = PermissionStore(
            activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id },
            connectionGeneration: { 1 },
            load: { id in await backend.pendingPermissions(id) },
            reply: { sessionID, requestID, decision in
                let outcome = await backend.replyPermission(sessionID, requestID: requestID)
                // Stands in for the server's `permission.replied` publication
                // so the list reconciles through the same fanout production
                // uses. The authoritative reread (not this event) clears it.
                if outcome == .accepted {
                    OfflineUITestComposition.deliverPermissionReplied(
                        sessionID: sessionID,
                        requestID: requestID,
                        decision: decision.rawValue,
                        to: eventOwner.fanout
                    )
                }
                return outcome
            }
        )
        ConversationComposition.bindPermission(permission, sessions: sessionStore, connectionOwner: model)
        // Same late-binding ownership as the transcript and execution stores:
        // the fanout replays the readiness marker below, so registration order
        // cannot hide it. The fixture then plays one `permission.asked`
        // through the same fanout production uses, so the seeded request
        // arrives via events as well as the authoritative read.
        ConversationComposition.bindPermissionEvents(permission, fanout: eventOwner.fanout)
        eventOwner.fanout.deliver(.connected(generation: 1))
        OfflineUITestComposition.deliverPermissionAsked(
            sessionID: SessionID(rawValue: "ses-fixture-a"),
            requestID: "per_fixture_allow",
            action: "edit",
            to: eventOwner.fanout
        )
        return (model, eventOwner, pickerModel, sessionStore, selectionStore, composer, transcript, execution, permission)
    }

    @MainActor private static func deliverInboxDelivered(sessionID: SessionID, to fanout: ConnectionEventFanout) {
        let json = "{\"id\":\"evt-fixture-\(UUID().uuidString)\",\"type\":\"session.inbox.delivered\",\"created\":1,\"data\":{\"sessionID\":\"\(sessionID.rawValue)\"}}"
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)) else { return }
        fanout.deliver(.event(generation: 1, envelope: envelope))
    }

    @MainActor private static func deliverExecution(_ transition: String, sessionID: SessionID, to fanout: ConnectionEventFanout) {
        executionSequence += 1
        let reason = transition == "interrupted" ? ",\"reason\":\"user\"" : ""
        let json = "{\"id\":\"evt_\(UUID().uuidString)\",\"type\":\"session.execution.\(transition)\",\"created\":1,\"durable\":{\"aggregateID\":\"\(sessionID.rawValue)\",\"seq\":\(executionSequence),\"version\":1},\"data\":{\"sessionID\":\"\(sessionID.rawValue)\"\(reason)}}"
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)) else { return }
        fanout.deliver(.event(generation: 1, envelope: envelope))
    }

    /// Fixture `permission.asked`: the payload carries the session that owns
    /// the request. The store attributes by `data.sessionID` and only
    /// invalidates; the authoritative read (never this event) writes the list.
    @MainActor static func deliverPermissionAsked(sessionID: SessionID, requestID: String, action: String, to fanout: ConnectionEventFanout) {
        let json = "{\"id\":\"evt_\(UUID().uuidString)\",\"type\":\"permission.asked\",\"created\":1,\"data\":{\"id\":\"\(requestID)\",\"sessionID\":\"\(sessionID.rawValue)\",\"action\":\"\(action)\",\"resources\":[\"/fixture/notes.txt\"]}}"
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)) else { return }
        fanout.deliver(.event(generation: 1, envelope: envelope))
    }

    /// Fixture `permission.replied` (`{sessionID, requestID, reply}`). Like
    /// `asked`, it only invalidates; the confirming reread reconciles.
    @MainActor static func deliverPermissionReplied(sessionID: SessionID, requestID: String, decision: String, to fanout: ConnectionEventFanout) {
        let json = "{\"id\":\"evt_\(UUID().uuidString)\",\"type\":\"permission.replied\",\"created\":1,\"data\":{\"sessionID\":\"\(sessionID.rawValue)\",\"requestID\":\"\(requestID)\",\"reply\":\"\(decision)\"}}"
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: Data(json.utf8)) else { return }
        fanout.deliver(.event(generation: 1, envelope: envelope))
    }
}

/// In-memory session/selection backend for the offline UI fixture.
/// Session A/B summaries, the injected catalogs, and the confirmed
/// selections are all served from here; nothing touches the network.
private actor OfflineFixtureBackend {
    private var active = Set<SessionID>()
    private var messages: [SessionID: [TranscriptMessage]] = [:]
    private var titles: [String: String] = [
        "ses-fixture-a": "Fixture Session A",
        "ses-fixture-b": "Fixture Session B",
    ]
    private var selectedAgent: String? = "build"
    private var selectedModel: ModelRef? = ModelRef(id: "claude", providerID: "anthropic")

    private static let catalogAgents: [AgentSummary] = [
        AgentSummary(info: AgentInfo(id: "build", name: "Build", description: "Fixture agent for offline UI tests.", mode: "primary", hidden: false)),
        AgentSummary(info: AgentInfo(id: "plan", name: "Plan", description: "Fixture agent for offline UI tests.", mode: "primary", hidden: false)),
    ]
    private static let catalogModels: [ModelSummary] = [
        ModelSummary(info: ModelInfo(id: "claude", providerID: "anthropic", name: "Claude", enabled: true, status: "active")),
        ModelSummary(info: ModelInfo(id: "gpt", providerID: "openai", name: "GPT", enabled: true, status: "active")),
    ]

    private func summary(id: SessionID) -> SessionSummary {
        SessionSummary(info: SessionInfo(
            id: id.rawValue,
            parentID: nil,
            projectID: "fixture-project",
            title: titles[id.rawValue],
            location: LocationRef(directory: "/fixture")
        ))
    }

    func list() -> SessionPage {
        let sessions = titles.keys.sorted().map { summary(id: SessionID(rawValue: $0)) }
        return SessionPage(sessions: sessions, nextCursor: nil, previousCursor: nil)
    }

    func get(_ id: SessionID) throws -> SessionSummary {
        guard titles[id.rawValue] != nil else { throw SessionAPIError.notFound }
        return summary(id: id)
    }

    func create(_ request: SessionCreateRequest, directory: URL) -> SessionSummary {
        titles[request.id.rawValue] = request.title ?? "Untitled Session"
        return summary(id: request.id)
    }

    func rename(_ id: SessionID, title: String) -> SessionRenameOutcome {
        guard titles[id.rawValue] != nil else { return .rejected(.notFound, authoritative: nil) }
        titles[id.rawValue] = title
        return .applied(authoritative: summary(id: id))
    }

    func agents() -> [AgentSummary] { Self.catalogAgents }

    func models() -> [ModelSummary] { Self.catalogModels }

    func selectAgent(_ id: SessionID, agent: String) -> SelectionMutationOutcome {
        guard Self.catalogAgents.contains(where: { $0.id == agent && $0.isPrimary }) else {
            return .rejected(.unavailable)
        }
        selectedAgent = agent
        return .applied(confirmed: SelectionConfirmation(agent: agent, model: selectedModel))
    }

    func selectModel(_ id: SessionID, model: ModelRef) -> SelectionMutationOutcome {
        guard Self.catalogModels.contains(where: { $0.ref == model && $0.enabled }) else {
            return .rejected(.unavailable)
        }
        selectedModel = model
        return .applied(confirmed: SelectionConfirmation(agent: selectedAgent, model: model))
    }

    func readSelection(_ id: SessionID) -> SelectionConfirmation {
        SelectionConfirmation(agent: selectedAgent, model: selectedModel)
    }

    func accept(_ request: PromptRequest) -> PromptSendResult {
        active.insert(request.sessionID)
        messages[request.sessionID, default: []].insert(.user(TranscriptTextMessage(id: request.messageID, created: 1, text: request.text)), at: 0)
        return .admitted(PromptAdmittedMessage(id: request.messageID, sessionID: request.sessionID.rawValue, type: "user", time: PromptInboxTime(created: 1), payload: PromptInboxPayload(text: request.text), delivery: .steer))
    }

    func history(_ id: SessionID) -> TranscriptPage {
        TranscriptPage(messages: messages[id] ?? [], cursor: TranscriptCursor(previous: nil, next: nil))
    }

    func activeSessions() -> Set<SessionID> { active }

    func interrupt(_ id: SessionID) -> Bool { active.remove(id) != nil }

    // MARK: - Pending permissions (R10)

    /// One seeded pending request owned by session A. Nothing touches the
    /// network; the composition adapter maps fixture outcomes to
    /// `PermissionReplyOutcome`, and the store's authoritative reread (never
    /// the event) reconciles the list after a reply.
    private var permissions: [String: [PermissionRequest]] = [
        "ses-fixture-a": [
            PermissionRequest(
                id: "per_fixture_allow",
                sessionID: "ses-fixture-a",
                action: "edit",
                resources: ["/fixture/notes.txt"],
                save: nil,
                metadata: nil,
                source: PermissionSource(type: "tool", messageID: "msg_fixture_1", id: "tool_fixture_1"),
                message: "Allow editing notes?"
            ),
        ],
    ]

    func pendingPermissions(_ id: SessionID) -> [PermissionRequest] {
        permissions[id.rawValue] ?? []
    }

    func replyPermission(_ id: SessionID, requestID: String) -> PermissionReplyOutcome {
        guard var list = permissions[id.rawValue],
              let index = list.firstIndex(where: { $0.id == requestID })
        else { return .notFound }
        list.remove(at: index)
        permissions[id.rawValue] = list
        return .accepted
    }
}

/// Never-opened event source for the offline fixture. The disconnected model
/// never yields a connection context, so this is never invoked.
private struct OfflineInertEventSource: ConnectionEventSubscriptionSource {
    func openConnectionEventSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> ConnectionEventSubscription {
        throw CancellationError()
    }
}
#endif
