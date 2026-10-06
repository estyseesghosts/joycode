import Foundation

/// Wires the selection store to the single passive service connection, the
/// active location, and the active session. Views only see the store.
enum SelectionComposition {
    @MainActor static func selectionStore(
        connectionOwner: ServiceConnectionOwner,
        location: any ActiveLocationProviding,
        sessionStore: ActiveSessionStore,
        transport: any HTTPTransport
    ) -> SelectionStore {
        let api = SelectionAPI(transport: transport)
        // Capture the publication generation alongside the connection so an
        // old-context mutation/discovery reply can never confirm current
        // selections after a connection replacement.
        let store = SelectionStore(
            location: location,
            activeSessionID: { [weak sessionStore] in sessionStore?.activeSession?.id },
            activeSessionDirectory: { [weak sessionStore] in sessionStore?.activeSession?.directory },
            connectionGeneration: { [weak connectionOwner] in connectionOwner?.currentContext?.generation },
            listAgents: { @MainActor @Sendable directory in
                guard let context = connectionOwner.currentContext else { throw SelectionAPIError.notConnected }
                return try await api.listAgents(connection: context.connection, location: directory).map(AgentSummary.init)
            },
            listModels: { @MainActor @Sendable directory in
                guard let context = connectionOwner.currentContext else { throw SelectionAPIError.notConnected }
                return try await api.listModels(connection: context.connection, location: directory).map(ModelSummary.init)
            },
            selectAgent: { @MainActor @Sendable sessionID, agent in
                guard let context = connectionOwner.currentContext else { return .rejected(.notConnected) }
                return Self.map(try await api.selectAgent(connection: context.connection, sessionID: sessionID, agent: agent))
            },
            selectModel: { @MainActor @Sendable sessionID, model in
                guard let context = connectionOwner.currentContext else { return .rejected(.notConnected) }
                return Self.map(try await api.selectModel(connection: context.connection, sessionID: sessionID, model: model))
            },
            readSelection: { @MainActor @Sendable sessionID in
                guard let context = connectionOwner.currentContext else { throw SelectionAPIError.notConnected }
                let selection = try await api.readSelection(connection: context.connection, sessionID: sessionID)
                return SelectionConfirmation(agent: selection.agent, model: selection.model)
            }
        )
        // Composition owns the session/location/connection subscription so
        // correctness never depends on SelectionView lifetime (the view
        // issues no automatic reads; manual Refresh stays forced).
        store.bind(sessionStore: sessionStore, connectionOwner: connectionOwner, location: location)
        return store
    }

    private static func map(_ result: SelectionMutationResult) -> SelectionMutationOutcome {
        switch result {
        case .applied(let confirmed):
            return .applied(confirmed: confirmed.map { SelectionConfirmation(agent: $0.agent, model: $0.model) })
        case .rejected(let error):
            return .rejected(SelectionProblem(error))
        case .unknown(let error):
            return .unknown(SelectionProblem(error))
        }
    }
}
