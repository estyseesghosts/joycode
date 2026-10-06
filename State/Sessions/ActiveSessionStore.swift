import Foundation
import Combine

@MainActor protocol ActiveLocationProviding: AnyObject { var activeLocation: ResolvedLocation? { get } }
extension ActiveLocationStore: ActiveLocationProviding {}

private enum SessionLoadOrigin { case explicit, restore }

enum SessionPersistenceProblem: Equatable, Sendable { case saveFailed }

@MainActor final class ActiveSessionStore: ObservableObject {
    @Published private(set) var state: ActiveSessionState = .empty
    @Published private(set) var roots: [SessionSummary] = []
    @Published private(set) var renameState: SessionRenameState = .idle
    /// Non-fatal overlay: the session is active now but was not saved for restart.
    @Published private(set) var persistenceProblem: SessionPersistenceProblem?
    var activeSession: SessionSummary? { if case .loaded(let value) = state { return value }; return nil }

    /// Retained here so composition can own the connection subscription without
    /// changing production call sites.
    var connectionSubscription: AnyCancellable?
    /// Retained here so production composition can own location observation
    /// (auto root refresh on chosen-folder change) without changing call sites.
    /// Folder changes only refresh the browsed root list; they never load,
    /// move, or discard the active session.
    var locationSubscription: AnyCancellable?

    /// Directory currently chosen for root browsing/new creation. The active
    /// session stays pinned to its own authoritative directory.
    var browsingDirectory: URL? { location.activeLocation?.directory }

    private let preferences: LocalPreferencesStore
    private let location: any ActiveLocationProviding
    private let list: @MainActor @Sendable (SessionListQuery) async throws -> SessionPage
    private let get: @MainActor @Sendable (SessionID) async throws -> SessionSummary
    private let createRequest: @MainActor @Sendable (SessionCreateRequest) async throws -> SessionSummary
    private let renameAction: @MainActor @Sendable (SessionID, String) async throws -> SessionRenameOutcome
    private let connectionReady: @MainActor () -> Bool
    private let connectionGeneration: @MainActor () -> UInt64?

    // Independent ownership: single-session reads (load/restore/recovery) share
    // loadTask/loadGeneration so explicit loads supersede restore reads, while
    // root refresh owns rootsTask/rootsGeneration so the two completion orders
    // cannot cancel or clobber each other.
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var rootsTask: Task<Void, Never>?
    private var rootsGeneration: UInt64 = 0
    private var createOperation: Task<Void, Never>?
    private var createGeneration: UInt64 = 0
    private var hasRestored = false
    private var restoreInFlightID: SessionID?
    private var pendingRestoreID: SessionID?
    private var lastNotedConnectionGeneration: UInt64?

    private var renameOperation: Task<Void, Never>?
    private var renameGeneration: UInt64 = 0
    private var activeRevision: UInt64 = 0
    private var lastObservedBrowsingDirectory: URL?

    private var renameIsInFlight: Bool {
        if case .inProgress = renameState { return true }
        if case .checking = renameState { return true }
        return false
    }

    init(preferences: LocalPreferencesStore, location: any ActiveLocationProviding, list: @escaping @MainActor @Sendable (SessionListQuery) async throws -> SessionPage, get: @escaping @MainActor @Sendable (SessionID) async throws -> SessionSummary, create: @escaping @MainActor @Sendable (SessionCreateRequest) async throws -> SessionSummary, rename: @escaping @MainActor @Sendable (SessionID, String) async throws -> SessionRenameOutcome = { _, _ in .rejected(.notConnected, authoritative: nil) }, connectionReady: @escaping @MainActor () -> Bool = { true }, connectionGeneration: @escaping @MainActor () -> UInt64? = { nil }) {
        self.preferences = preferences; self.location = location; self.list = list; self.get = get; self.createRequest = create; self.renameAction = rename; self.connectionReady = connectionReady; self.connectionGeneration = connectionGeneration
    }

    func restore() {
        guard !renameIsInFlight else { return }
        clearStaleRenameTerminal()
        do {
            guard let id = try preferences.load().lastSessionID else {
                // No selection is itself a newer fact, but it must not
                // override an in-flight or unresolved explicit mutation.
                switch state {
                case .creating, .creationUnknown: return
                default: break
                }
                // Invalidate any older restore read so it cannot resurrect a
                // cleared selection.
                pendingRestoreID = nil; restoreInFlightID = nil
                loadGeneration &+= 1; loadTask?.cancel(); loadTask = nil
                state = .empty; return
            }
            // Prefer no action while not ready: record the pending restore and
            // settle visibly; the connection note starts the read. Never
            // disturb explicit or in-flight work, and never regress a loaded
            // session that needs no restoration.
            guard connectionReady() else {
                switch state {
                case .creating, .creationUnknown, .loading, .loaded: return
                default: break
                }
                pendingRestoreID = id; restoreInFlightID = nil
                state = .failed(.notConnected)
                return
            }
            beginLoad(id, origin: .restore)
        }
        catch { state = .failed(.preferencesUnreadable) }
    }
    func restoreIfNeeded() { guard !hasRestored else { return }; hasRestored = true; restore() }

    /// Composition calls this on every connection-context change. A pending
    /// restore (a restore read that lost its connection) retries exactly once
    /// per new ready generation, only from a settled state, and never while an
    /// explicit load/select/create/clear owns the session.
    func noteConnectionContext(_ generation: UInt64?) {
        guard generation != lastNotedConnectionGeneration else { return }
        lastNotedConnectionGeneration = generation
        guard connectionReady(), generation != nil, pendingRestoreID != nil else { return }
        guard !renameIsInFlight else { return }
        switch state {
        case .empty, .failed: break
        default: return
        }
        pendingRestoreID = nil
        restore()
    }

    func refreshRoots() {
        guard let directory = location.activeLocation?.directory else {
            // No chosen folder: clear the browsed list without issuing a
            // request, and preserve the active loaded/loading session state.
            rootsGeneration &+= 1; rootsTask?.cancel(); rootsTask = nil
            lastObservedBrowsingDirectory = nil
            roots = []
            return
        }
        lastObservedBrowsingDirectory = directory
        rootsGeneration &+= 1; let attempt = rootsGeneration
        let connectionAttempt = connectionGeneration()
        let revisionAtStart = activeRevision
        let directoryAttempt = directory
        let work = list
        rootsTask?.cancel()
        rootsTask = Task { @MainActor [weak self] in
            // Never dispatch a known-stale queued list: re-validate ownership
            // inside the task before touching transport.
            guard let self, self.rootsGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt) else { return }
            guard self.location.activeLocation?.directory == directoryAttempt else { return }
            do { let page = try await work(.init(parent: .roots, directory: directoryAttempt)); guard self.rootsGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else { return }
                guard self.location.activeLocation?.directory == directoryAttempt else { return }
                if self.activeRevision != revisionAtStart {
                    // A newer authoritative/local fact about the active session arrived
                    // after this list started — do NOT let the older list regress it.
                    let activeID = activeSession?.id
                    roots = page.sessions.map { session in
                        if session.id == activeID, let currentActive = activeSession { return currentActive }
                        return session
                    }
                } else {
                    roots = page.sessions
                    if case .loaded = state, let id = activeSession?.id, let fetched = page.sessions.first(where: { $0.id == id }) {
                        publishActive(fetched)
                    }
                }
            }
            catch is CancellationError {} catch { guard self.rootsGeneration == attempt else { return }; guard self.sameConnection(connectionAttempt) else { return }; guard self.location.activeLocation?.directory == directoryAttempt else { return }; switch state { case .loaded, .creating, .creationUnknown, .loading: break; default: state = .failed(Self.problem(error)) } }
        }
    }

    /// Production composition calls this on chosen-folder changes. It is
    /// idempotent per directory: only a new directory triggers a refresh, and
    /// it never loads, moves, or discards the active session.
    func noteBrowsingDirectoryChanged() {
        let current = location.activeLocation?.directory
        guard current != lastObservedBrowsingDirectory else { return }
        refreshRoots()
    }
    func load(_ id: SessionID) {
        beginLoad(id, origin: .explicit)
    }
    func selectRoot(_ id: SessionID) {
        load(id)
    }
    func rename(_ draft: String) {
        guard case .loaded(let current) = state else { return }
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != current.title else { return }
        if case .inProgress = renameState { return }
        if case .checking = renameState { return }
        if case .rejected = renameState { renameGeneration &+= 1; renameOperation?.cancel() }
        if case .unknown = renameState { renameGeneration &+= 1; renameOperation?.cancel() }
        let request = SessionRenameRequest(sessionID: current.id, title: title)
        // Never dispatch a mutation into a known-dead connection: record the
        // rejection without sending.
        guard connectionReady() else { renameState = .rejected(request, .notConnected, serverTitle: nil); return }
        renameGeneration &+= 1; let attempt = renameGeneration
        loadGeneration &+= 1; loadTask?.cancel(); loadTask = nil
        rootsGeneration &+= 1; rootsTask?.cancel(); rootsTask = nil
        let connectionAttempt = connectionGeneration()
        renameState = .inProgress(request)
        let action = renameAction
        renameOperation = Task { @MainActor [weak self] in
            // Re-validate ownership inside the task: a queued intent must not
            // dispatch on a replaced connection. Unsent intents reject without
            // sending; only sent mutations may become unknown.
            guard let self, self.renameGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt), self.connectionReady() else {
                guard self.renameGeneration == attempt else { return }
                if case .inProgress(let current) = self.renameState, current == request {
                    self.renameState = .rejected(request, .notConnected, serverTitle: nil)
                }
                return
            }
            do {
                let outcome = try await action(current.id, title)
                guard self.renameGeneration == attempt else { return }
                self.applyRenameOutcome(outcome, request: request, connectionAttempt: connectionAttempt)
            } catch is CancellationError {
                guard self.renameGeneration == attempt else { return }
                // The action was invoked before cancellation, so the mutation
                // was sent with an unknown outcome — even when the connection
                // generation is unchanged. Preserve the draft request/title.
                if case .inProgress(let current) = self.renameState, current == request {
                    self.renameState = .unknown(request, serverTitle: nil)
                } else if case .checking(let current) = self.renameState, current == request {
                    self.renameState = .unknown(request, serverTitle: nil)
                }
            } catch {
                guard self.renameGeneration == attempt else { return }
                self.renameState = .unknown(request, serverTitle: nil)
            }
        }
    }
    func checkRename() {
        guard case .unknown(let request, _) = renameState, case .loaded = state, activeSession?.id == request.sessionID else { return }
        renameGeneration &+= 1; let attempt = renameGeneration
        let connectionAttempt = connectionGeneration()
        renameState = .checking(request)
        let reader = get
        renameOperation = Task { @MainActor [weak self] in
            guard let self, self.renameGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt), self.connectionReady() else {
                guard self.renameGeneration == attempt else { return }
                if case .checking(let r) = self.renameState, r == request { self.renameState = .unknown(request, serverTitle: nil) }
                return
            }
            guard self.activeSession?.id == request.sessionID else {
                guard self.renameGeneration == attempt else { return }
                if case .checking(let r) = self.renameState, r == request { self.renameState = .unknown(request, serverTitle: nil) }
                return
            }
            do {
                let value = try await reader(request.sessionID)
                guard self.renameGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else {
                    if case .checking(let r) = self.renameState, r == request { self.renameState = .unknown(request, serverTitle: nil) }
                    return
                }
                guard value.id == request.sessionID else {
                    if case .checking(let r) = self.renameState, r == request { self.renameState = .unknown(request, serverTitle: nil) }
                    return
                }
                if value.id == request.sessionID { publishActive(value) }
                if value.id == request.sessionID, value.title == request.title { renameState = .idle }
                else { renameState = .unknown(request, serverTitle: value.title) }
            } catch is CancellationError {
                guard self.renameGeneration == attempt else { return }
                if case .checking(let r) = renameState, r == request { renameState = .unknown(request, serverTitle: nil) }
            } catch {
                guard self.renameGeneration == attempt else { return }
                if case .checking(let r) = renameState, r == request { renameState = .unknown(request, serverTitle: nil) }
            }
        }
    }
    func create(title: String? = nil) {
        guard !renameIsInFlight else { return }
        clearStaleRenameTerminal()
        guard let directory = location.activeLocation?.directory else { state = .creationRejected(.noLocation); return }
        switch state { case .creating, .creationUnknown, .loading: return; default: break }
        // Never dispatch a mutation into a known-dead connection.
        guard connectionReady() else { state = .creationRejected(.notConnected); return }
        pendingRestoreID = nil; restoreInFlightID = nil; hasRestored = true
        let id = SessionID(rawValue: "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let connectionAttempt = connectionGeneration()
        createGeneration &+= 1; let attempt = createGeneration; state = .creating; let work = createRequest
        createOperation = Task { @MainActor [weak self] in
            guard let self, self.createGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt), self.connectionReady() else {
                guard self.createGeneration == attempt else { return }
                if self.state == .creating { self.state = .creationRejected(.notConnected) }
                return
            }
            do {
                let value = try await work(SessionCreateRequest(id: id, title: title, location: directory))
                guard self.createGeneration == attempt else { return }
                // A sent create that lost its connection stays unknown: the reply
                // cannot be adopted as a fact in the new connection context.
                guard self.sameConnection(connectionAttempt) else { self.state = .creationUnknown(id); return }
                guard value.id == id else { self.state = .creationUnknown(id); return }
                self.recordPersistence { try self.persist(id) }; self.publishActive(value)
            }
            catch is CancellationError {
                guard self.createGeneration == attempt else { return }
                // A cancelled create was sent with an unknown outcome: never
                // leave .creating stuck, and never claim success or rejection.
                self.state = .creationUnknown(id)
            } catch let error as SessionAPIError {
                guard self.createGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else { self.state = .creationUnknown(id); return }
                switch error { case .unauthorized: state = .creationRejected(.unauthorized); case .notConnected: state = .creationRejected(.notConnected); case .backend(400): state = .creationRejected(.backend(400)); default: state = .creationUnknown(id) }
            }
            catch { guard self.createGeneration == attempt else { return }; guard self.sameConnection(connectionAttempt) else { self.state = .creationUnknown(id); return }; state = .creationUnknown(id) }
        }
    }
    func recoverUnknownCreation() {
        guard case .creationUnknown(let id) = state else { return }
        pendingRestoreID = nil; restoreInFlightID = nil; hasRestored = true
        loadGeneration &+= 1; let attempt = loadGeneration
        let connectionAttempt = connectionGeneration()
        let work = get
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt) else { return }
            do {
                let value = try await work(id)
                guard self.loadGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else { return }
                guard value.id == id else { return }
                self.recordPersistence { try self.persist(id) }; self.publishActive(value)
            }
            catch is CancellationError {} catch let error as SessionAPIError { guard self.loadGeneration == attempt else { return }; guard self.sameConnection(connectionAttempt) else { return }; if case .notFound = error { state = .empty } }
            catch {}
        }
    }
    func clear() { loadGeneration &+= 1; loadTask?.cancel(); loadTask = nil; rootsGeneration &+= 1; rootsTask?.cancel(); rootsTask = nil; renameGeneration &+= 1; renameOperation?.cancel(); renameOperation = nil; renameState = .idle; createGeneration &+= 1; createOperation?.cancel(); createOperation = nil; pendingRestoreID = nil; restoreInFlightID = nil; hasRestored = true; recordPersistence { try clearPreference() }; state = .empty }

    private func beginLoad(_ id: SessionID, origin: SessionLoadOrigin) {
        guard !renameIsInFlight else { return }
        clearStaleRenameTerminal()
        switch state {
        case .creating, .creationUnknown: return
        case .loading where origin == .restore: return
        default: break
        }
        if origin == .restore, restoreInFlightID == id { return }
        if origin == .explicit { pendingRestoreID = nil; restoreInFlightID = nil; hasRestored = true }
        else { restoreInFlightID = id }
        loadGeneration &+= 1; let attempt = loadGeneration
        let prior = state
        let connectionAttempt = connectionGeneration()
        state = .loading; let work = get
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == attempt else { return }
            guard self.sameConnection(connectionAttempt) else { self.handleStaleConnectionRead(id: id, origin: origin, prior: prior); return }
            do {
                let value = try await work(id)
                guard self.loadGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else { self.handleStaleConnectionRead(id: id, origin: origin, prior: prior); return }
                guard value.id == id else {
                    if origin == .restore { self.restoreInFlightID = nil }
                    self.state = .failed(.requestFailed)
                    return
                }
                if origin == .restore { self.restoreInFlightID = nil; self.pendingRestoreID = nil }
                self.recordPersistence { try self.persist(id) }; self.publishActive(value)
            }
            catch is CancellationError {
                guard self.loadGeneration == attempt else { return }
                self.handleCancelledRead(id: id, origin: origin, prior: prior)
            }
            catch let error as SessionAPIError {
                guard self.loadGeneration == attempt else { return }
                self.handleLoadAPIError(error, id: id, origin: origin, prior: prior, connectionAttempt: connectionAttempt)
            }
            catch {
                guard self.loadGeneration == attempt else { return }
                guard self.sameConnection(connectionAttempt) else { self.handleStaleConnectionRead(id: id, origin: origin, prior: prior); return }
                if origin == .restore { self.restoreInFlightID = nil }
                self.state = .failed(.requestFailed)
            }
        }
    }

    private func handleLoadAPIError(_ error: SessionAPIError, id: SessionID, origin: SessionLoadOrigin, prior: ActiveSessionState, connectionAttempt: UInt64?) {
        if origin == .restore { restoreInFlightID = nil }
        guard sameConnection(connectionAttempt) else {
            handleStaleConnectionRead(id: id, origin: origin, prior: prior)
            return
        }
        if case .notFound = error { pendingRestoreID = nil; recordPersistence { try clearPreference() }; state = .empty; return }
        state = .failed(Self.problem(error))
        if origin == .restore, error == .notConnected { pendingRestoreID = id }
    }

    private func handleStaleConnectionRead(id: SessionID, origin: SessionLoadOrigin, prior: ActiveSessionState) {
        guard origin == .restore else {
            // Explicit reads never publish across a connection replacement and
            // never spin: newer state is left alone, .loading is resolved.
            if state == .loading {
                state = connectionReady() ? (prior == .loading ? .empty : prior) : .failed(.notConnected)
            }
            return
        }
        restoreInFlightID = nil
        pendingRestoreID = id
        guard state == .loading else { return }
        state = prior == .loading ? .empty : prior
        if connectionReady() { restore() }
        else if state == .empty { state = .failed(.notConnected) }
    }

    private func handleCancelledRead(id: SessionID, origin: SessionLoadOrigin, prior: ActiveSessionState) {
        if origin == .restore { restoreInFlightID = nil }
        guard state == .loading else { return }
        if origin == .restore {
            pendingRestoreID = id
            state = connectionReady() ? (prior == .loading ? .empty : prior) : .failed(.notConnected)
        } else {
            state = prior == .loading ? .empty : prior
        }
    }

    private func clearStaleRenameTerminal() {
        if case .rejected = renameState { renameGeneration &+= 1; renameOperation?.cancel(); renameState = .idle }
        if case .unknown = renameState { renameGeneration &+= 1; renameOperation?.cancel(); renameState = .idle }
    }

    private func sameConnection(_ captured: UInt64?) -> Bool { connectionGeneration() == captured }
    private func persist(_ id: SessionID) throws { var p = try preferences.load(); p.lastSessionID = id; try preferences.save(p) }
    /// Runs one restart-affecting write and records its outcome. Failure only
    /// sets the warning; `state` and backend facts are never touched.
    private func recordPersistence(_ write: () throws -> Void) {
        do { try write(); persistenceProblem = nil } catch { persistenceProblem = .saveFailed }
    }
    private func clearPreference() throws { var p = try preferences.load(); p.lastSessionID = nil; try preferences.save(p) }
    private func publishActive(_ value: SessionSummary) {
        state = .loaded(value)
        activeRevision &+= 1
        roots = authoritativeRoots(roots)
    }
    private func authoritativeRoots(_ values: [SessionSummary]) -> [SessionSummary] { guard case .loaded(let active) = state else { return values }; return values.map { $0.id == active.id ? active : $0 } }

    private func applyRenameOutcome(_ outcome: SessionRenameOutcome, request: SessionRenameRequest, connectionAttempt: UInt64?) {
        // A sent rename that lost its connection stays unknown and never adopts
        // facts read on the old connection; a pre-send rejection keeps its
        // classification.
        let connected = sameConnection(connectionAttempt)
        switch outcome {
        case .applied(let authoritative):
            if connected, let authoritative, authoritative.id == request.sessionID { publishActive(authoritative) }
            if !connected { renameState = .unknown(request, serverTitle: nil) }
            else if let authoritative, authoritative.id == request.sessionID, authoritative.title == request.title { renameState = .idle }
            else if let authoritative, authoritative.id != request.sessionID { renameState = .unknown(request, serverTitle: nil) }
            else { renameState = .unknown(request, serverTitle: authoritative?.title) }
        case .rejected(let problem, let authoritative):
            if connected, let authoritative, authoritative.id == request.sessionID { publishActive(authoritative) }
            let serverTitle: String? = (connected && authoritative?.id == request.sessionID) ? authoritative?.title : nil
            renameState = .rejected(request, problem, serverTitle: serverTitle)
        case .unknown(_, let authoritative):
            if connected, let authoritative, authoritative.id == request.sessionID { publishActive(authoritative) }
            if !connected { renameState = .unknown(request, serverTitle: nil) }
            else if let authoritative, authoritative.id == request.sessionID, authoritative.title == request.title { renameState = .idle }
            else if let authoritative, authoritative.id != request.sessionID { renameState = .unknown(request, serverTitle: nil) }
            else { renameState = .unknown(request, serverTitle: authoritative?.title) }
        }
    }

    private static func problem(_ error: Error) -> SessionProblem { guard let error = error as? SessionAPIError else { return .requestFailed }; switch error { case .notConnected: return .notConnected; case .unauthorized: return .unauthorized; case .notFound: return .notFound; case .backend(let n): return .backend(n); case .malformedResponse: return .malformedResponse; case .requestFailed: return .requestFailed } }
}
