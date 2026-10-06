import Combine
import Foundation

/// Application-owned conversation stores. Construction is passive; requests
/// require an already-discovered connection and a loaded session.
enum ConversationComposition {
    @MainActor static func execution(connectionOwner: ServiceConnectionOwner, sessions: ActiveSessionStore, eventOwner: ConnectionEventOwner, transport: any HTTPTransport) -> ExecutionStatusStore {
        let api = ExecutionAPI(transport: transport)
        let store = ExecutionStatusStore(activeSessionID: { [weak sessions] in sessions?.activeSession?.id }, connectionGeneration: { [weak connectionOwner] in connectionOwner?.currentContext?.generation }, loadActive: { @MainActor @Sendable in
            guard let context = connectionOwner.currentContext else { throw ExecutionAPIError.notConnected }
            return try await api.activeSessions(connection: context.connection)
        }, interrupt: { @MainActor @Sendable id in
            guard let context = connectionOwner.currentContext else { return .failed }
            do {
                return try await api.interrupt(connection: context.connection, sessionID: id) ? .accepted : .notInterrupted
            } catch let error as ExecutionAPIError {
                return interruptReply(for: error)
            } catch {
                // Cancellation or a lost reply is not evidence of rejection.
                return .unknown
            }
        })
        bindExecution(store, sessions: sessions, connectionOwner: connectionOwner)
        bindExecutionEvents(store, fanout: eventOwner.fanout)
        return store
    }

    static func interruptReply(for error: ExecutionAPIError) -> ExecutionInterruptReply {
        if error == .busy { return .busy }
        return ExecutionAPI.isDeclaredRejection(error) ? .failed : .unknown
    }

    @MainActor static func bindExecutionEvents(_ store: ExecutionStatusStore, fanout: ConnectionEventFanout) {
        store.eventObservation = fanout.addObserver { [weak store] signal in store?.receive(signal) }
    }

    @MainActor static func bindExecution(_ store: ExecutionStatusStore, sessions: ActiveSessionStore, connectionOwner: ServiceConnectionOwner) {
        sessions.$state.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        connectionOwner.$currentContext.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        store.contextChanged()
    }

    /// Production permission approvals. Construction is passive; reads and
    /// replies require an already-discovered connection and a loaded session.
    /// Transport mapping lives here (see `PermissionAPI`); the store consumes
    /// only pending lists and `PermissionReplyOutcome` values. Execution state
    /// is untouched: pending approvals are a separate row, never a `blocked`
    /// inference on the execution store.
    @MainActor static func permission(connectionOwner: ServiceConnectionOwner, sessions: ActiveSessionStore, eventOwner: ConnectionEventOwner, transport: any HTTPTransport) -> PermissionStore {
        let api = PermissionAPI(transport: transport)
        let store = PermissionStore(activeSessionID: { [weak sessions] in sessions?.activeSession?.id }, connectionGeneration: { [weak connectionOwner] in connectionOwner?.currentContext?.generation }, load: { @MainActor @Sendable id in
            guard let context = connectionOwner.currentContext else { throw PermissionAPIError.notConnected }
            return try await api.pendingRequests(connection: context.connection, sessionID: id)
        }, reply: { @MainActor @Sendable sessionID, requestID, decision in
            guard let context = connectionOwner.currentContext else { return .unknown }
            do {
                try await api.reply(connection: context.connection, sessionID: sessionID, requestID: requestID, decision: Self.permissionDecision(decision), message: nil)
                return .accepted
            } catch let error as PermissionAPIError {
                return Self.permissionReply(for: error)
            } catch {
                // Cancellation or a lost reply is not evidence of rejection or success.
                return .unknown
            }
        })
        bindPermission(store, sessions: sessions, connectionOwner: connectionOwner)
        bindPermissionEvents(store, fanout: eventOwner.fanout)
        return store
    }

    /// P1 policy: only `once`/`reject` reach the wire. `always` needs a
    /// separate policy disposition and is never offered.
    static func permissionDecision(_ choice: PermissionChoice) -> PermissionDecision {
        switch choice {
        case .once: return .once
        case .reject: return .reject
        }
    }

    /// A missing request (`404`) is honest absence, never success. Declared
    /// rejections (`400`/`401`) surface as rejected; every other status,
    /// transport failure, or malformed body is conservatively unknown and must
    /// never retry.
    static func permissionReply(for error: PermissionAPIError) -> PermissionReplyOutcome {
        if error == .notFound { return .notFound }
        return PermissionAPI.isDeclaredRejection(error) ? .rejected : .unknown
    }

    /// Store-owned observation of the application event fanout. Late binding
    /// is safe: the fanout replays the current ready/failed phase. Single
    /// fanout, composition-owned; the view creates no observation tasks.
    @MainActor static func bindPermissionEvents(_ store: PermissionStore, fanout: ConnectionEventFanout) {
        store.eventObservation = fanout.addObserver { [weak store] signal in store?.receive(signal) }
    }

    /// Composition owns the session/connection subscription so correctness
    /// never depends on PermissionView lifetime. A changed context clears
    /// per-context facts promptly inside the store; subscriptions are retained
    /// in `contextSubscriptions`.
    @MainActor static func bindPermission(_ store: PermissionStore, sessions: ActiveSessionStore, connectionOwner: ServiceConnectionOwner) {
        sessions.$state.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        connectionOwner.$currentContext.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        store.contextChanged()
    }

    @MainActor static func composer(connectionOwner: ServiceConnectionOwner, sessions: ActiveSessionStore, selection: SelectionStore, transport: any HTTPTransport) -> ComposerStore {
        let api = PromptAPI(transport: transport)
        let store = ComposerStore(context: { [weak sessions, weak selection, weak connectionOwner] in
            ComposerContext(sessionID: sessions?.activeSession?.id,
                            directory: sessions?.activeSession?.directory,
                            connectionGeneration: connectionOwner?.currentContext?.generation,
                            isReady: selection?.isSelectionCurrent == true && selection?.selectedAgent != nil && selection?.selectedModel != nil)
        }, send: { @MainActor @Sendable request in
            guard let context = connectionOwner.currentContext else { return .rejected(.notConnected) }
            return try await api.send(connection: context.connection, request: request)
        })
        store.bind(sessionStore: sessions, selectionStore: selection, connectionOwner: connectionOwner)
        return store
    }

    /// The transcript hydrates after the event stream's readiness marker, so
    /// the first snapshot cannot predate the live subscriber registration.
    @MainActor static func transcript(connectionOwner: ServiceConnectionOwner, sessions: ActiveSessionStore, eventOwner: ConnectionEventOwner, transport: any HTTPTransport) -> TranscriptStore {
        let api = TranscriptAPI(transport: transport)
        let store = TranscriptStore(activeSessionID: { [weak sessions] in sessions?.activeSession?.id }, connectionGeneration: { [weak connectionOwner] in connectionOwner?.currentContext?.generation }, awaitsEventStream: true, load: { @MainActor @Sendable id, query in
            guard let context = connectionOwner.currentContext else { throw TranscriptAPIError.notConnected }
            return try await api.page(connection: context.connection, sessionID: id, query: query)
        }, loadMessage: { @MainActor @Sendable id, messageID in
            guard let context = connectionOwner.currentContext else { throw TranscriptAPIError.notConnected }
            return try await api.message(connection: context.connection, sessionID: id, messageID: messageID)
        })
        bindTranscript(store, sessions: sessions, connectionOwner: connectionOwner)
        bindTranscriptEvents(store, fanout: eventOwner.fanout)
        return store
    }

    /// Store-owned observation of the application event fanout. Late binding
    /// is safe: the fanout replays the current ready/failed phase.
    @MainActor static func bindTranscriptEvents(_ store: TranscriptStore, fanout: ConnectionEventFanout) {
        store.eventObservation = fanout.addObserver { [weak store] signal in store?.receive(signal) }
    }

    @MainActor static func bindTranscript(_ store: TranscriptStore, sessions: ActiveSessionStore, connectionOwner: ServiceConnectionOwner) {
        sessions.$state.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        connectionOwner.$currentContext.receive(on: DispatchQueue.main).sink { [weak store] _ in
            Task { @MainActor [weak store] in store?.contextChanged() }
        }.store(in: &store.contextSubscriptions)
        store.contextChanged()
    }
}
