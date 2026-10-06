import Foundation
import Combine

enum SessionComposition {
    @MainActor static func activeSessionStore(connectionOwner: ServiceConnectionOwner, location: any ActiveLocationProviding, preferences: LocalPreferencesStore, transport: any HTTPTransport) -> ActiveSessionStore {
        let api = SessionAPI(transport: transport)
        let store = ActiveSessionStore(preferences: preferences, location: location, list: { @MainActor @Sendable query in
            guard let context = connectionOwner.currentContext else { throw SessionAPIError.notConnected }
            let envelope = try await api.list(connection: context.connection, query: query)
            return SessionPage(sessions: envelope.data.map(SessionSummary.init), nextCursor: envelope.cursor.next, previousCursor: envelope.cursor.previous)
        }, get: { @MainActor @Sendable id in
            guard let context = connectionOwner.currentContext else { throw SessionAPIError.notConnected }
            return SessionSummary(info: try await api.get(connection: context.connection, sessionID: id))
        }, create: { @MainActor @Sendable request in
            guard let context = connectionOwner.currentContext else { throw SessionAPIError.notConnected }
            return SessionSummary(info: try await api.create(connection: context.connection, request: request))
        }, rename: { @MainActor @Sendable id, title in
            guard let context = connectionOwner.currentContext else {
                return .rejected(.notConnected, authoritative: nil)
            }
            let result = try await api.rename(connection: context.connection, sessionID: id, title: title)
            switch result {
            case .applied(let info):
                return .applied(authoritative: info.map(SessionSummary.init))
            case .rejected(let error, let info):
                return .rejected(SessionProblem(error), authoritative: info.map(SessionSummary.init))
            case .unknown(let error, let info):
                return .unknown(SessionProblem(error), authoritative: info.map(SessionSummary.init))
            }
        }, connectionReady: { [weak connectionOwner] in connectionOwner?.currentContext != nil }, connectionGeneration: { [weak connectionOwner] in connectionOwner?.currentContext?.generation })
        // Connection-aware restore: a restore read that failed with
        // notConnected retries once the connection reports a new ready
        // generation. The store retains the subscription; duplicate generations
        // and explicit load/select/create/clear activity suppress the retry.
        store.connectionSubscription = connectionOwner.$currentContext
            .receive(on: DispatchQueue.main)
            .sink { [weak store] context in
                Task { @MainActor [weak store] in store?.noteConnectionContext(context?.generation) }
            }
        store.noteConnectionContext(connectionOwner.currentContext?.generation)
        // Chosen-folder changes scope root browsing/new creation only. Observe
        // the location store where available and auto-refresh the browsed root
        // list idempotently; never load, move, or discard the active session.
        if let locationStore = location as? ActiveLocationStore {
            store.locationSubscription = locationStore.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak store] state in
                    Task { @MainActor [weak store] in
                        // Resolving is transient: activeLocation reads nil while
                        // the same folder verifies; reacting would spuriously
                        // clear the browsed roots. Genuine clears/failures still
                        // flow through noteBrowsingDirectoryChanged.
                        if case .resolving = state { return }
                        store?.noteBrowsingDirectoryChanged()
                    }
                }
        }
        return store
    }
}
