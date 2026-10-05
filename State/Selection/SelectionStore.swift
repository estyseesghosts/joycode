import Foundation
import Combine

/// Session-scoped selection state for the primary agent and model.
///
/// The backend is authoritative: this store only publishes a selected value
/// after the documented mutation is accepted (`204`). Agent and model selection
/// are independently maintained and independently superseded, so switching one
/// never discards the other. Discovery and selection are guarded by request
/// generations so a late response cannot regress newer state or a different
/// active session.
@MainActor final class SelectionStore: ObservableObject {
    @Published private(set) var agents: [AgentSummary] = []
    @Published private(set) var models: [ModelSummary] = []
    @Published private(set) var agentDiscovery: SelectionDiscoveryState = .idle
    @Published private(set) var modelDiscovery: SelectionDiscoveryState = .idle
    @Published private(set) var selectedAgent: String?
    @Published private(set) var selectedModel: ModelRef?
    @Published private(set) var agentSelection: AgentSelectionState = .idle
    @Published private(set) var modelSelection: ModelSelectionState = .idle
    @Published private(set) var selectionSessionID: SessionID?
    @Published private(set) var isChecking = false
    /// Non-nil when the active session's authoritative selection could not be read.
    @Published private(set) var hydrationProblem: SelectionProblem?
    /// Directory scoping the currently published catalogs. The active session's
    /// authoritative directory scopes catalogs/mutations; the chosen folder is
    /// only a fallback when there is no active session.
    @Published private(set) var catalogDirectory: URL?
    /// True while an authoritative selection read for the active session is in
    /// flight. Part of the R06 readiness seam alongside `selectionConnection`.
    @Published private(set) var isHydrating = false
    /// Connection generation that published the current selected values, or
    /// nil when nothing is published yet or the last publication was
    /// invalidated (session scope reset, connection replaced). R06 readiness:
    /// selected values are current only when `isSelectionCurrent` holds; a
    /// non-nil `hydrationProblem` names the truthful failure.
    @Published private(set) var selectionConnection: UInt64?

    /// Whether the published selection is current for the active session on
    /// the active connection. Retained values from a replaced connection read
    /// as stale, never as current. Both axes must be authoritatively
    /// published on the current connection with no unresolved (busy/unknown)
    /// axis, no hydration in flight, and no surfaced hydration problem; the
    /// authoritative session directory must also match.
    var isSelectionCurrent: Bool {
        guard let sessionID = activeSessionID(), sessionID == selectionSessionID else { return false }
        guard activeSessionDirectory() == selectionSessionDirectory else { return false }
        guard !isHydrating, hydrationProblem == nil, !hasUnresolvedAxis else { return false }
        guard let current = connectionGeneration(),
              let agentPublished = agentPublishedConnection, agentPublished == current,
              let modelPublished = modelPublishedConnection, modelPublished == current else { return false }
        return true
    }

    private let location: any ActiveLocationProviding
    private let activeSessionID: @MainActor () -> SessionID?
    private let activeSessionDirectory: @MainActor () -> URL?
    private let connectionGeneration: @MainActor () -> UInt64?
    private let listAgentsAction: @MainActor @Sendable (URL) async throws -> [AgentSummary]
    private let listModelsAction: @MainActor @Sendable (URL) async throws -> [ModelSummary]
    private let selectAgentAction: @MainActor @Sendable (SessionID, String) async throws -> SelectionMutationOutcome
    private let selectModelAction: @MainActor @Sendable (SessionID, ModelRef) async throws -> SelectionMutationOutcome
    private let readSelectionAction: @MainActor @Sendable (SessionID) async throws -> SelectionConfirmation

    private var discoveryGeneration: UInt64 = 0
    private var agentDiscoveryOperation: Task<Void, Never>?
    private var modelDiscoveryOperation: Task<Void, Never>?

    private var agentSelectionGeneration: UInt64 = 0
    private var agentSelectionOperation: Task<Void, Never>?
    private var modelSelectionGeneration: UInt64 = 0
    private var modelSelectionOperation: Task<Void, Never>?

    /// Per-axis authoritative publication revision. Advanced every time the
    /// corresponding selected value is authoritatively published: own-mutation
    /// application, counterpart adoption from a mutation readback, hydration,
    /// or explicit-check reconciliation. Together with the selection
    /// generations this guards cross-axis readback adoption: a mutation
    /// snapshots the opposite revision at start and adopts the opposite-axis
    /// readback only when nothing was published on that axis while it was in
    /// flight. Generation guards alone miss hydration/reconciliation/
    /// counterpart publications (no new mutation started); busy checks alone
    /// miss an opposite mutation that already completed.
    private var agentRevision: UInt64 = 0
    private var modelRevision: UInt64 = 0

    private var checkGeneration: UInt64 = 0
    private var checkOperation: Task<Void, Never>?

    private var sessionSyncGeneration: UInt64 = 0
    private var sessionSyncOperation: Task<Void, Never>?

    /// Session directory tracked alongside selectionSessionID so a same-ID
    /// directory change still resets session scope and invalidates catalogs.
    private var selectionSessionDirectory: URL?
    /// In-flight discovery context; results publish only on an exact match.
    private var discoveryDirectory: URL?
    private var discoverySessionID: SessionID?
    private var discoveryConnection: UInt64?
    /// Context of the last successfully published catalogs. Mutations require
    /// an exact directory + connection match so session B can never mutate
    /// from catalog A while rediscovery is pending.
    private var loadedSessionID: SessionID?
    private var loadedConnection: UInt64?
    private var bindings = Set<AnyCancellable>()
    /// Last session/directory/connection context the binding already acted on.
    /// Automatic triggers discover only on a key change, so initial publisher
    /// replays collapse to one discover and title-only session updates cause
    /// none. Manual `discover()` is always forced and re-keys. This key dedupes
    /// discovery only; connection hydration currency is tracked separately via
    /// `lastObservedConnectionKey` so a session/folder refresh that already
    /// re-keyed discovery cannot swallow a same-turn reconnect hydration reset.
    private var observedContextKey: String?
    /// Last connection generation the hydration seam acted on ("off" when
    /// disconnected, nil when never observed). `connectionChanged` dedupes on
    /// this marker alone, never on the full discovery context key.
    private var lastObservedConnectionKey: String?
    /// Per-axis authoritative publication connection. A single-axis applied
    /// mutation must not bless the retained other-axis value as current across
    /// a reconnect; readiness requires both axes published on the current
    /// connection (hydration publishes both together).
    private var agentPublishedConnection: UInt64?
    private var modelPublishedConnection: UInt64?

    /// Agents the backend reports as selectable primaries (mode `primary`/`all`, not hidden).
    var primaryAgents: [AgentSummary] { agents.filter(\.isPrimary) }

    /// Models the backend reports as enabled.
    var selectableModels: [ModelSummary] { models.filter(\.enabled) }

    init(
        location: any ActiveLocationProviding,
        activeSessionID: @escaping @MainActor () -> SessionID?,
        activeSessionDirectory: @escaping @MainActor () -> URL? = { nil },
        connectionGeneration: @escaping @MainActor () -> UInt64? = { 0 },
        listAgents: @escaping @MainActor @Sendable (URL) async throws -> [AgentSummary],
        listModels: @escaping @MainActor @Sendable (URL) async throws -> [ModelSummary],
        selectAgent: @escaping @MainActor @Sendable (SessionID, String) async throws -> SelectionMutationOutcome,
        selectModel: @escaping @MainActor @Sendable (SessionID, ModelRef) async throws -> SelectionMutationOutcome,
        readSelection: @escaping @MainActor @Sendable (SessionID) async throws -> SelectionConfirmation
    ) {
        self.location = location
        self.activeSessionID = activeSessionID
        self.activeSessionDirectory = activeSessionDirectory
        self.connectionGeneration = connectionGeneration
        self.listAgentsAction = listAgents
        self.listModelsAction = listModels
        self.selectAgentAction = selectAgent
        self.selectModelAction = selectModel
        self.readSelectionAction = readSelection
    }

    /// Authoritative directory for catalogs/mutations: the active session's
    /// directory when a session exists, otherwise the chosen folder fallback.
    var effectiveDirectory: URL? { activeSessionDirectory() ?? location.activeLocation?.directory }

    /// Session/directory/connection key scoping catalogs, mutations, and
    /// hydration. Title-only session updates leave the key unchanged.
    private func contextKey() -> String {
        let id = activeSessionID()?.rawValue ?? "none"
        let directory = effectiveDirectory?.path ?? "nodir"
        let connection = connectionGeneration().map(String.init) ?? "off"
        return "\(id)|\(directory)|\(connection)"
    }

    /// Connection-only currency marker ("off" when disconnected).
    private func connectionKey() -> String {
        connectionGeneration().map(String.init) ?? "off"
    }

    /// True while either axis is busy or truthfully unknown (rejected leaves
    /// prior currency intact; idle is settled).
    private var hasUnresolvedAxis: Bool {
        switch agentSelection {
        case .unknown, .inProgress: return true
        case .idle, .rejected: break
        }
        switch modelSelection {
        case .unknown, .inProgress: return true
        case .idle, .rejected: break
        }
        return false
    }

    /// Automatic entry point for binding triggers: discovers only when the
    /// context key changed since the last acted-on context.
    private func refreshForContextChange() {
        let key = contextKey()
        guard key != observedContextKey else { return }
        observedContextKey = key
        discover()
    }

    // MARK: - Discovery

    /// Discovers primary agents and models for the effective directory. Agent
    /// and model discovery publish independently so one failure does not hide
    /// the other. Stale results (directory/session/connection changed) are
    /// discarded; no transport is invoked while disconnected. Always forced:
    /// binding dedupe lives in `refreshForContextChange`, so manual Refresh
    /// and tests always re-issue. Every path re-keys the observed context and
    /// clears catalog currency on failure scope loss (including disconnect).
    func discover() {
        observedContextKey = contextKey()
        guard let directory = effectiveDirectory else {
            discoveryGeneration &+= 1
            agentDiscoveryOperation?.cancel(); agentDiscoveryOperation = nil
            modelDiscoveryOperation?.cancel(); modelDiscoveryOperation = nil
            discoveryDirectory = nil; discoverySessionID = nil; discoveryConnection = nil
            catalogDirectory = nil; loadedSessionID = nil; loadedConnection = nil
            agents = []
            models = []
            agentDiscovery = .failed(.noLocation)
            modelDiscovery = .failed(.noLocation)
            return
        }
        guard let connection = connectionGeneration() else {
            discoveryGeneration &+= 1
            agentDiscoveryOperation?.cancel(); agentDiscoveryOperation = nil
            modelDiscoveryOperation?.cancel(); modelDiscoveryOperation = nil
            discoveryDirectory = nil; discoverySessionID = nil; discoveryConnection = nil
            catalogDirectory = nil; loadedSessionID = nil; loadedConnection = nil
            agents = []
            models = []
            agentDiscovery = .failed(.notConnected)
            modelDiscovery = .failed(.notConnected)
            return
        }

        discoveryGeneration &+= 1
        let attempt = discoveryGeneration
        let session = activeSessionID()
        discoveryDirectory = directory
        discoverySessionID = session
        discoveryConnection = connection
        agentDiscoveryOperation?.cancel()
        modelDiscoveryOperation?.cancel()
        agentDiscovery = .loading
        modelDiscovery = .loading

        let agentWork = listAgentsAction
        agentDiscoveryOperation = Task { @MainActor [weak self] in
            // Never resolve a backend call for a stale intent: re-validate the
            // captured context before dispatching.
            guard let self, self.discoveryGeneration == attempt else { return }
            guard self.discoveryDirectory == self.effectiveDirectory,
                  self.discoverySessionID == self.activeSessionID(),
                  self.discoveryConnection == self.connectionGeneration() else { return }
            do {
                let result = try await agentWork(directory)
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.agents = result
                self.agentDiscovery = .loaded
                self.catalogDirectory = directory
                self.loadedSessionID = session
                self.loadedConnection = connection
            } catch is CancellationError {
                // A current-generation cancellation must not leave a stale
                // loading state: report a truthful transport failure. Stale
                // generations (superseded discover) stay silent.
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.agents = []
                self.agentDiscovery = .failed(.requestFailed)
            } catch {
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.agents = []
                self.agentDiscovery = .failed(Self.problem(error))
            }
        }

        let modelWork = listModelsAction
        modelDiscoveryOperation = Task { @MainActor [weak self] in
            guard let self, self.discoveryGeneration == attempt else { return }
            guard self.discoveryDirectory == self.effectiveDirectory,
                  self.discoverySessionID == self.activeSessionID(),
                  self.discoveryConnection == self.connectionGeneration() else { return }
            do {
                let result = try await modelWork(directory)
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.models = result
                self.modelDiscovery = .loaded
                self.catalogDirectory = directory
                self.loadedSessionID = session
                self.loadedConnection = connection
            } catch is CancellationError {
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.models = []
                self.modelDiscovery = .failed(.requestFailed)
            } catch {
                guard self.discoveryGeneration == attempt else { return }
                guard self.discoveryDirectory == self.effectiveDirectory,
                      self.discoverySessionID == self.activeSessionID(),
                      self.discoveryConnection == self.connectionGeneration() else { return }
                self.models = []
                self.modelDiscovery = .failed(Self.problem(error))
            }
        }
    }

    /// Composition-owned subscription: correctness never depends on view
    /// lifetime (SelectionView issues no automatic reads). Session facts reset
    /// session scope and re-discover only on a context-key change, so
    /// title-only updates cause no duplicate discover; folder changes only
    /// re-discover when there is no active session (fallback mode); connection
    /// changes re-scope catalogs and re-read authoritative selection.
    /// Disconnected changes never invoke transport. Initial publisher replays
    /// collapse to a single discover via the context key.
    func bind(sessionStore: ActiveSessionStore, connectionOwner: ServiceConnectionOwner, location: any ActiveLocationProviding) {
        bindings.removeAll()
        sessionStore.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    // Transient busies never re-scope: only settled session
                    // facts drive selection scope and discovery.
                    switch state {
                    case .loading, .creating, .creationUnknown: return
                    default: break
                    }
                    self.activeSessionChanged()
                    self.refreshForContextChange()
                }
            }
            .store(in: &bindings)
        connectionOwner.$currentContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.connectionChanged()
                }
            }
            .store(in: &bindings)
        if let locationStore = location as? ActiveLocationStore {
            locationStore.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in
                        // Resolving is transient: activeLocation reads nil while
                        // the same folder verifies, so reacting would spuriously
                        // clear catalogs to noLocation. Genuine clears/failures
                        // (empty/needsRecovery) still flow through.
                        if case .resolving = state { return }
                        // Chosen folder is only a fallback when no session exists;
                        // folder changes while a session is pinned must retain catalogs A.
                        guard self.activeSessionID() == nil else { return }
                        self.refreshForContextChange()
                    }
                }
                .store(in: &bindings)
        }
    }

    /// Reacts to a replaced service connection for the same session scope.
    /// A same-ID reconnect cannot hydrate via `activeSessionChanged` (the id
    /// is unchanged), so this invalidates prior hydration currency and starts
    /// a new authoritative selection read when ready — without clearing
    /// `unknown` mutation state, confirming old values, or blind-retrying.
    /// Retained selected values read as stale (`isSelectionCurrent == false`)
    /// until the fresh read confirms them; reads never fire while
    /// disconnected (truthful `.notConnected` instead).
    func connectionChanged() {
        // Hydration currency dedupes on the connection marker alone: a
        // session/folder refresh may have already re-keyed discovery for the
        // new connection, but it must never swallow the reconnect hydration
        // reset. Discovery itself stays deduped on the full context key.
        let connKey = connectionKey()
        guard connKey != lastObservedConnectionKey else { return }
        lastObservedConnectionKey = connKey
        sessionSyncGeneration &+= 1
        sessionSyncOperation?.cancel()
        sessionSyncOperation = nil
        isHydrating = false
        selectionConnection = nil
        agentPublishedConnection = nil
        modelPublishedConnection = nil
        let key = contextKey()
        if key != observedContextKey {
            discover()
        } else {
            // Discovery already current for the new connection (a refresh won
            // the race): still need the hydration reset above plus a fresh
            // authoritative read below. Re-discovering would only churn
            // generations, so skip the duplicate transport.
        }
        guard let sessionID = activeSessionID(), sessionID == selectionSessionID else { return }
        guard connectionGeneration() != nil else {
            hydrationProblem = .notConnected
            return
        }
        // An in-flight mutation or explicit check owns selection currency
        // through its own readback; starting a hydration here would disturb it.
        // Settled rejections do not block: reconnect must re-read authority.
        guard isHydrationPermitted else { return }
        syncSelection(sessionID: sessionID)
    }

    // MARK: - Selection

    /// Selects a discovered primary agent for the active session. A newer
    /// selection supersedes an in-flight one; success is published only after
    /// the backend accepts the mutation.
    func selectAgent(_ agent: String) {
        guard let sessionID = activeSessionID() else {
            agentSelection = .rejected(agent: agent, problem: .noSession)
            return
        }
        guard let effective = effectiveDirectory else {
            agentSelection = .rejected(agent: agent, problem: .noLocation)
            return
        }
        guard let startConnection = connectionGeneration() else {
            agentSelection = .rejected(agent: agent, problem: .notConnected)
            return
        }
        guard agentDiscovery == .loaded, catalogDirectory == effective, loadedConnection == startConnection, loadedSessionID == sessionID else {
            // Catalogs for the current directory/connection are not loaded
            // (rediscovery pending): never mutate from a stale catalog.
            agentSelection = .rejected(agent: agent, problem: .unavailable)
            return
        }
        guard primaryAgents.contains(where: { $0.id == agent }) else {
            agentSelection = .rejected(agent: agent, problem: .unavailable)
            return
        }
        adopt(sessionID: sessionID)
        if case .idle = agentSelection, selectedAgent == agent { return }

        invalidateSessionSync()
        agentSelectionGeneration &+= 1
        let attempt = agentSelectionGeneration
        agentSelectionOperation?.cancel()
        cancelCheck()
        let startModelGen = modelSelectionGeneration
        let startModelRevision = modelRevision
        let startModelBusy: Bool
        if case .inProgress = modelSelection { startModelBusy = true } else { startModelBusy = false }
        let startDirectory = effective
        agentSelection = .inProgress(agent: agent)
        let work = selectAgentAction
        agentSelectionOperation = Task { @MainActor [weak self] in
            // Never resolve a backend call for a stale intent: re-validate the
            // captured context before dispatching.
            guard let self, self.agentSelectionGeneration == attempt else { return }
            guard self.connectionGeneration() == startConnection else {
                self.agentSelection = .unknown(agent: agent, problem: .notConnected)
                return
            }
            guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.agentSelection = .idle; return }
            do {
                let outcome = try await work(sessionID, agent)
                guard self.agentSelectionGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID else { self.agentSelection = .idle; return }
                // Directory/session moved while the mutation was in flight:
                // never confirm session B from a catalog-A mutation.
                guard self.effectiveDirectory == startDirectory else { self.agentSelection = .idle; return }
                // Connection replaced while in flight: the old-context reply
                // must not confirm current selections. Qualify unknown; never
                // blind-retry — the user re-issues explicitly.
                guard self.connectionGeneration() == startConnection else {
                    self.agentSelection = .unknown(agent: agent, problem: .notConnected)
                    return
                }
                self.applyAgentOutcome(outcome, requested: agent, connection: startConnection, startModelGen: startModelGen, startModelRevision: startModelRevision, startModelBusy: startModelBusy)
            } catch is CancellationError {
                guard self.agentSelectionGeneration == attempt else { return }
                // Cancelled after dispatch with the context intact: the reply
                // was lost, so qualify unknown — never confirm, never retry.
                // A moved session/directory/connection already owns the state.
                guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.agentSelection = .idle; return }
                guard self.connectionGeneration() == startConnection else {
                    self.agentSelection = .unknown(agent: agent, problem: .notConnected)
                    return
                }
                self.agentSelection = .unknown(agent: agent, problem: .requestFailed)
            } catch {
                guard self.agentSelectionGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.agentSelection = .idle; return }
                guard self.connectionGeneration() == startConnection else {
                    self.agentSelection = .unknown(agent: agent, problem: .notConnected)
                    return
                }
                self.agentSelection = .unknown(agent: agent, problem: .requestFailed)
            }
        }
    }

    /// Selects a discovered model for the active session. Agent state is untouched.
    func selectModel(_ model: ModelRef) {
        guard let sessionID = activeSessionID() else {
            modelSelection = .rejected(model: model, problem: .noSession)
            return
        }
        guard let effective = effectiveDirectory else {
            modelSelection = .rejected(model: model, problem: .noLocation)
            return
        }
        guard let startConnection = connectionGeneration() else {
            modelSelection = .rejected(model: model, problem: .notConnected)
            return
        }
        guard modelDiscovery == .loaded, catalogDirectory == effective, loadedConnection == startConnection, loadedSessionID == sessionID else {
            modelSelection = .rejected(model: model, problem: .unavailable)
            return
        }
        guard selectableModels.contains(where: { $0.ref == model }) else {
            modelSelection = .rejected(model: model, problem: .unavailable)
            return
        }
        adopt(sessionID: sessionID)
        if case .idle = modelSelection, selectedModel == model { return }

        invalidateSessionSync()
        modelSelectionGeneration &+= 1
        let attempt = modelSelectionGeneration
        modelSelectionOperation?.cancel()
        cancelCheck()
        let startAgentGen = agentSelectionGeneration
        let startAgentRevision = agentRevision
        let startAgentBusy: Bool
        if case .inProgress = agentSelection { startAgentBusy = true } else { startAgentBusy = false }
        let startDirectory = effective
        modelSelection = .inProgress(model: model)
        let work = selectModelAction
        modelSelectionOperation = Task { @MainActor [weak self] in
            guard let self, self.modelSelectionGeneration == attempt else { return }
            guard self.connectionGeneration() == startConnection else {
                self.modelSelection = .unknown(model: model, problem: .notConnected)
                return
            }
            guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.modelSelection = .idle; return }
            do {
                let outcome = try await work(sessionID, model)
                guard self.modelSelectionGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID else { self.modelSelection = .idle; return }
                guard self.effectiveDirectory == startDirectory else { self.modelSelection = .idle; return }
                guard self.connectionGeneration() == startConnection else {
                    self.modelSelection = .unknown(model: model, problem: .notConnected)
                    return
                }
                self.applyModelOutcome(outcome, requested: model, connection: startConnection, startAgentGen: startAgentGen, startAgentRevision: startAgentRevision, startAgentBusy: startAgentBusy)
            } catch is CancellationError {
                guard self.modelSelectionGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.modelSelection = .idle; return }
                guard self.connectionGeneration() == startConnection else {
                    self.modelSelection = .unknown(model: model, problem: .notConnected)
                    return
                }
                self.modelSelection = .unknown(model: model, problem: .requestFailed)
            } catch {
                guard self.modelSelectionGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID, self.effectiveDirectory == startDirectory else { self.modelSelection = .idle; return }
                guard self.connectionGeneration() == startConnection else {
                    self.modelSelection = .unknown(model: model, problem: .notConnected)
                    return
                }
                self.modelSelection = .unknown(model: model, problem: .requestFailed)
            }
        }
    }

    /// Resets session-scoped selection when the active session id or its
    /// authoritative directory changes, cancels in-flight work for the
    /// previous context, and best-effort hydrates the new session's
    /// authoritative selection from the documented session read.
    func activeSessionChanged() {
        let current = activeSessionID()
        let currentDirectory = activeSessionDirectory()
        guard current != selectionSessionID || currentDirectory != selectionSessionDirectory else { return }
        adopt(sessionID: current, directory: currentDirectory)
        if let current { syncSelection(sessionID: current) }
    }

    /// Reconciles an `unknown` selection against the documented session read.
    /// The reply must arrive on the same session, directory, and connection
    /// that sent the mutation; an old-context reply never confirms current
    /// selections and no blind retry is issued.
    func checkSelection() {
        guard let sessionID = activeSessionID(), sessionID == selectionSessionID else { return }
        guard let startConnection = connectionGeneration() else { return }
        guard let startDirectory = effectiveDirectory else { return }
        let hasUnknown: Bool
        if case .unknown = agentSelection { hasUnknown = true }
        else if case .unknown = modelSelection { hasUnknown = true }
        else { hasUnknown = false }
        guard hasUnknown else { return }

        invalidateSessionSync()
        checkGeneration &+= 1
        let attempt = checkGeneration
        checkOperation?.cancel()
        isChecking = true
        let reader = readSelectionAction
        checkOperation = Task { @MainActor [weak self] in
            guard let self, self.checkGeneration == attempt else { return }
            guard self.activeSessionID() == sessionID,
                  self.effectiveDirectory == startDirectory,
                  self.connectionGeneration() == startConnection else { self.isChecking = false; return }
            do {
                let confirmation = try await reader(sessionID)
                guard self.checkGeneration == attempt else { return }
                self.isChecking = false
                guard self.activeSessionID() == sessionID else { return }
                guard self.effectiveDirectory == startDirectory else { return }
                guard self.connectionGeneration() == startConnection else { return }
                self.reconcile(confirmation, connection: startConnection)
            } catch is CancellationError {
                guard self.checkGeneration == attempt else { return }
                self.isChecking = false
            } catch {
                guard self.checkGeneration == attempt else { return }
                self.isChecking = false
                // Remain qualified `unknown`; a lost read cannot prove success.
            }
        }
    }

    // MARK: - Internals

    private func adopt(sessionID: SessionID?, directory: URL? = nil) {
        // Directory defaults to the current authoritative directory so legacy
        // single-argument adopters (same-session selections) stay no-ops.
        let resolvedDirectory = directory ?? activeSessionDirectory()
        guard selectionSessionID != sessionID || selectionSessionDirectory != resolvedDirectory else { return }
        selectionSessionID = sessionID
        selectionSessionDirectory = resolvedDirectory
        selectedAgent = nil
        selectedModel = nil
        // Scope reset invalidates all prior selection currency.
        selectionConnection = nil
        agentPublishedConnection = nil
        modelPublishedConnection = nil
        isHydrating = false
        agentSelectionGeneration &+= 1; agentSelectionOperation?.cancel(); agentSelectionOperation = nil
        modelSelectionGeneration &+= 1; modelSelectionOperation?.cancel(); modelSelectionOperation = nil
        cancelCheck()
        invalidateSessionSync()
        agentSelection = .idle
        modelSelection = .idle
    }

    private func invalidateSessionSync() {
        sessionSyncGeneration &+= 1
        sessionSyncOperation?.cancel()
        sessionSyncOperation = nil
        isHydrating = false
        hydrationProblem = nil
    }

    private func cancelCheck() {
        checkGeneration &+= 1
        checkOperation?.cancel()
        checkOperation = nil
        isChecking = false
    }

    /// Hydration gate: settled `idle`/`rejected` on both axes with no explicit
    /// check in flight. Readiness treats `rejected` as settled, so a rejected
    /// attempt must not block reconnect/retry hydration; `inProgress`/`unknown`
    /// own currency through their own readback/check instead.
    private var isHydrationPermitted: Bool {
        if isChecking { return false }
        switch agentSelection {
        case .idle, .rejected: break
        case .inProgress, .unknown: return false
        }
        switch modelSelection {
        case .idle, .rejected: break
        case .inProgress, .unknown: return false
        }
        return true
    }

    /// Best-effort hydration of the active session's authoritative selection.
    /// A newer selection supersedes this read; a failed read fabricates
    /// nothing. Replies from a replaced connection or a moved directory never
    /// publish. Successful reads stamp `selectionConnection` so R06 can tell
    /// current selections from retained-but-stale ones.
    private func syncSelection(sessionID: SessionID) {
        guard let startConnection = connectionGeneration() else { return }
        let startDirectory = effectiveDirectory
        sessionSyncGeneration &+= 1
        let attempt = sessionSyncGeneration
        sessionSyncOperation?.cancel()
        isHydrating = true
        // A fresh authoritative read on a ready generation supersedes the
        // previous hydration failure; clear it before the read lands.
        hydrationProblem = nil
        let reader = readSelectionAction
        sessionSyncOperation = Task { @MainActor [weak self] in
            guard let self, self.sessionSyncGeneration == attempt else { return }
            guard self.activeSessionID() == sessionID, self.selectionSessionID == sessionID,
                  self.effectiveDirectory == startDirectory,
                  self.connectionGeneration() == startConnection else { self.isHydrating = false; return }
            do {
                let confirmation = try await reader(sessionID)
                guard self.sessionSyncGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID, self.selectionSessionID == sessionID else { self.isHydrating = false; return }
                guard self.effectiveDirectory == startDirectory else { self.isHydrating = false; return }
                guard self.connectionGeneration() == startConnection else { self.isHydrating = false; return }
                guard self.isHydrationPermitted else { self.isHydrating = false; return }
                self.selectedAgent = confirmation.agent
                self.selectedModel = confirmation.model
                self.agentRevision &+= 1
                self.modelRevision &+= 1
                self.selectionConnection = startConnection
                self.agentPublishedConnection = startConnection
                self.modelPublishedConnection = startConnection
                self.hydrationProblem = nil
                self.isHydrating = false
            } catch is CancellationError {
                guard self.sessionSyncGeneration == attempt else { return }
                self.isHydrating = false
            } catch {
                guard self.sessionSyncGeneration == attempt else { return }
                guard self.activeSessionID() == sessionID, self.selectionSessionID == sessionID else { self.isHydrating = false; return }
                guard self.effectiveDirectory == startDirectory else { self.isHydrating = false; return }
                guard self.connectionGeneration() == startConnection else { self.isHydrating = false; return }
                self.hydrationProblem = Self.problem(error)
                self.isHydrating = false
            }
        }
    }

    /// Re-attempts the authoritative read for the active session after a failed
    /// hydration. It cannot fabricate a selection; it only reports what the
    /// documented session read returns. Never fires while disconnected or
    /// while a hydration is already in flight.
    func retryHydration() {
        guard connectionGeneration() != nil, !isHydrating else { return }
        guard let sessionID = activeSessionID(), sessionID == selectionSessionID, isHydrationPermitted else { return }
        syncSelection(sessionID: sessionID)
    }

    private func applyAgentOutcome(_ outcome: SelectionMutationOutcome, requested: String, connection: UInt64, startModelGen: UInt64, startModelRevision: UInt64, startModelBusy: Bool) {
        switch outcome {
        case .applied(let confirmed):
            selectedAgent = confirmed?.agent ?? requested
            agentRevision &+= 1
            agentPublishedConnection = connection
            selectionConnection = connection
            // Adopt the authoritative cross-axis model only when the sample
            // cannot be stale: no model mutation was already in flight at
            // start, none is in flight at outcome, no model mutation started
            // while we were in flight, and no authoritative model value was
            // published (own applied, counterpart adoption, hydration,
            // reconciliation) while we were in flight.
            let modelIdleNow: Bool
            if case .inProgress = modelSelection { modelIdleNow = false } else { modelIdleNow = true }
            if let model = confirmed?.model,
               !startModelBusy,
               modelIdleNow,
               startModelGen == modelSelectionGeneration,
               startModelRevision == modelRevision {
                selectedModel = model
                modelRevision &+= 1
                modelPublishedConnection = connection
            }
            agentSelection = .idle
        case .rejected(let problem):
            agentSelection = .rejected(agent: requested, problem: problem)
        case .unknown(let problem):
            agentSelection = .unknown(agent: requested, problem: problem)
        }
    }

    private func applyModelOutcome(_ outcome: SelectionMutationOutcome, requested: ModelRef, connection: UInt64, startAgentGen: UInt64, startAgentRevision: UInt64, startAgentBusy: Bool) {
        switch outcome {
        case .applied(let confirmed):
            selectedModel = confirmed?.model ?? requested
            modelRevision &+= 1
            modelPublishedConnection = connection
            selectionConnection = connection
            // Symmetric cross-axis guard; see applyAgentOutcome.
            let agentIdleNow: Bool
            if case .inProgress = agentSelection { agentIdleNow = false } else { agentIdleNow = true }
            if let agent = confirmed?.agent,
               !startAgentBusy,
               agentIdleNow,
               startAgentGen == agentSelectionGeneration,
               startAgentRevision == agentRevision {
                selectedAgent = agent
                agentRevision &+= 1
                agentPublishedConnection = connection
            }
            modelSelection = .idle
        case .rejected(let problem):
            modelSelection = .rejected(model: requested, problem: problem)
        case .unknown(let problem):
            modelSelection = .unknown(model: requested, problem: problem)
        }
    }

    private func reconcile(_ confirmation: SelectionConfirmation, connection: UInt64) {
        if case .unknown(let agent, _) = agentSelection, confirmation.agent == agent {
            selectedAgent = agent
            agentRevision &+= 1
            agentPublishedConnection = connection
            selectionConnection = connection
            agentSelection = .idle
        }
        if case .unknown(let model, _) = modelSelection, confirmation.model == model {
            selectedModel = model
            modelRevision &+= 1
            modelPublishedConnection = connection
            selectionConnection = connection
            modelSelection = .idle
        }
    }

    private static func problem(_ error: Error) -> SelectionProblem {
        guard let error = error as? SelectionAPIError else { return .requestFailed }
        return SelectionProblem(error)
    }
}
