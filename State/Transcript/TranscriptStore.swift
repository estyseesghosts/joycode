import Foundation
import Combine

/// How trustworthy the displayed transcript is relative to the live stream.
/// Never claims `live` without positive evidence; every other case says why.
enum TranscriptSynchronization: Equatable, Sendable {
    /// No usable session or connection.
    case unavailable
    /// The active session was deleted (verified `session.deleted`).
    case sessionRemoved
    /// The latest snapshot request failed; retained records are not current.
    case refreshFailed
    /// The event stream ended or failed; later changes may have been missed.
    case streamLost
    /// Waiting for the stream readiness marker before the first snapshot.
    case awaitingStream
    /// First snapshot is in flight and nothing is published yet.
    case hydrating
    /// A snapshot is shown without a ready stream (explicit refresh, or no
    /// event source attached). Not live.
    case snapshotOnly
    /// An event-known change is not yet reflected in the published snapshot.
    case resyncing
    /// Stream ready, and the published snapshot began after the last
    /// event-known change.
    case live
}

/// Transcript state for the current session: authoritative snapshots of the
/// most recent 50 records, kept current by event-driven invalidation and
/// conservative resynchronization.
///
/// Pinned OpenCode v2.0.20 (`GET /api/session/{id}/message` -> `200
/// {data: Session.Message.Info[], cursor}`; history defaults to 50
/// newest-first, limits 1...200, server page order is authoritative internal
/// sequence, not timestamp; see `docs/plan/r06-r07-contract-notes-2026-10-05.md`
/// and `docs/plan/r08-live-reconciliation-2026-10-05.md`).
///
/// Reconciliation model (R08). The public event stream is live-only and has no
/// replay, exactly-once or total-order guarantee, and history snapshots carry
/// no sequence comparable to event sequence. So events are never merged into
/// records and never ranked against snapshots. Instead:
/// - A history-affecting event for the active session bumps a local
///   `invalidationEpoch`. A snapshot request remembers the epoch it started
///   under; if events arrived meanwhile, the reply is still published (it is
///   at least as recent as the displayed one) but the store reports
///   `resyncing` and requests another snapshot. Bursts coalesce into one
///   debounced follow-up; at most one request is in flight for events.
/// - Removals are the only event facts the store keeps: `session.revert.
///   committed` records its boundary message and drops that message and every
///   later displayed one; replies whose request began before the removal are
///   discarded and refetched; later snapshots are filtered by the tombstones.
///   `session.deleted` clears the session and blocks further hydration.
/// - `server.connected` is the readiness marker (the server registers the
///   subscriber before emitting it). With `awaitsEventStream`, the first
///   snapshot starts only after it, and readiness itself invalidates any
///   snapshot taken earlier. Stream failure marks the store `streamLost`
///   rather than clearing records; recovery is R13.
/// - Events with an unidentifiable session refresh the active session.
///   Ephemeral deltas are not applied.
///
/// Context model: the active session and connection generation form the
/// request context. A snapshot publishes only on an exact match of request
/// generation (newest request wins), session and connection generation.
/// `contextChanged()` is the store-owned seam composition binds to; a changed
/// context cancels work, clears display and tombstones, and hydrates when the
/// new context is usable. A refresh that fails while its context is current
/// retains published records, marked stale. Records are never re-sorted by
/// timestamp; the default newest-first page is reversed exactly once.
@MainActor final class TranscriptStore: ObservableObject {
    /// Chronological presentation order (default `desc` page reversed once;
    /// never timestamp-sorted).
    @Published private(set) var messages: [TranscriptMessage] = []
    /// True while a snapshot request is in flight.
    @Published private(set) var isLoading = false
    /// True when the published records are retained but not current (a
    /// same-context refresh failed or was cancelled after records existed).
    @Published private(set) var isStale = false
    /// The failure of the latest same-context refresh, if any. Cleared on
    /// success and on context replacement.
    @Published private(set) var lastError: TranscriptAPIError?
    /// Session the published records belong to, if any.
    @Published private(set) var publishedSessionID: SessionID?
    /// Connection generation that published the current records, if any.
    @Published private(set) var publishedConnection: UInt64?
    /// Why the display can or cannot be called current.
    @Published private(set) var synchronization: TranscriptSynchronization = .unavailable

    private let activeSessionID: @MainActor () -> SessionID?
    private let connectionGeneration: @MainActor () -> UInt64?
    private let loadPage: @MainActor @Sendable (SessionID, TranscriptQuery) async throws -> TranscriptPage
    private let awaitsEventStream: Bool
    private let resyncDelay: Duration

    private var requestGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var observedSessionID: SessionID?
    private var observedConnection: UInt64?
    var contextSubscriptions = Set<AnyCancellable>()
    /// Composition-owned observation of the application event fanout.
    var eventObservation: ConnectionEventObservation?

    // Per-context reconciliation state. Reset whenever session or connection
    // changes; epochs are local counters, never server facts.
    private var invalidationEpoch: UInt64 = 0
    private var removalEpoch: UInt64 = 0
    private var publishedEpoch: UInt64?
    private var removedMessageIDs: [String] = []
    private var revertBoundaries: [String] = []
    private static let maximumRemovedMessageIDs = 1024
    private static let maximumRevertBoundaries = 32

    // Per-connection stream and deletion knowledge.
    private var readyConnection: UInt64?
    private var failedConnection: UInt64?
    private var removedSession: (session: SessionID, connection: UInt64)?

    var unavailableMessage: String? {
        guard let session = activeSessionID() else { return "No active session." }
        guard let connection = connectionGeneration() else { return "Not connected. History is unavailable." }
        if isRemoved(session, connection) { return "This session was deleted." }
        return nil
    }

    init(
        activeSessionID: @escaping @MainActor () -> SessionID?,
        connectionGeneration: @escaping @MainActor () -> UInt64?,
        awaitsEventStream: Bool = false,
        resyncDelay: Duration = .milliseconds(150),
        load: @escaping @MainActor @Sendable (SessionID, TranscriptQuery) async throws -> TranscriptPage
    ) {
        self.activeSessionID = activeSessionID
        self.connectionGeneration = connectionGeneration
        self.awaitsEventStream = awaitsEventStream
        self.resyncDelay = resyncDelay
        self.loadPage = load
    }

    // MARK: - Snapshots

    /// Explicit refresh of the most recent snapshot (default: newest 50).
    /// Supersedes any in-flight or scheduled request. Retains the current
    /// records until the replacement arrives; a repeated full refresh
    /// replaces by stable server identity and never appends. Works without a
    /// ready stream, in which case the result is `snapshotOnly`.
    func refresh(query: TranscriptQuery = .defaultPage) {
        let session = activeSessionID()
        let connection = connectionGeneration()
        if session != observedSessionID || connection != observedConnection {
            resetContext()
        }
        observedSessionID = session
        observedConnection = connection
        cancelResyncTimer()
        guard let session, let connection else {
            // Nil context disables transport: no request is dispatched.
            requestGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            publishSynchronization()
            return
        }
        guard !isRemoved(session, connection) else {
            publishSynchronization()
            return
        }
        startSnapshot(session: session, connection: connection, query: query)
    }

    private func startSnapshot(session: SessionID, connection: UInt64, query: TranscriptQuery) {
        requestGeneration &+= 1
        let attempt = requestGeneration
        let startEpoch = invalidationEpoch
        loadTask?.cancel()
        isLoading = true
        publishSynchronization()
        let work = loadPage
        loadTask = Task { @MainActor [weak self] in
            guard let self, self.requestGeneration == attempt else { return }
            guard self.isCurrent(session, connection) else { return }
            do {
                let page = try await work(session, query)
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                self.publish(page, query: query, startEpoch: startEpoch, session: session, connection: connection)
            } catch is CancellationError {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                // Cancelled with context intact: settle visibly without
                // clearing retained records.
                self.isLoading = false
                if !self.messages.isEmpty { self.isStale = true }
                self.publishSynchronization()
            } catch {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                // Same-context failure retains records, marked stale/failed.
                self.isLoading = false
                self.isStale = true
                if let apiError = error as? TranscriptAPIError {
                    self.lastError = apiError
                } else {
                    self.lastError = .requestFailed
                }
                self.publishSynchronization()
            }
        }
    }

    private func publish(
        _ page: TranscriptPage,
        query: TranscriptQuery,
        startEpoch: UInt64,
        session: SessionID,
        connection: UInt64
    ) {
        isLoading = false
        guard startEpoch >= removalEpoch else {
            // The request began before a verified removal, so it may still
            // contain deleted records. Keep the tombstone-filtered display
            // and read again; never publish the old reply.
            publishSynchronization()
            scheduleResync(delay: .zero)
            return
        }
        let presented = applyingTombstones(to: Self.presented(serverOrdered: page.messages, query: query))
        if presented != messages { messages = presented }
        publishedSessionID = session
        publishedConnection = connection
        publishedEpoch = startEpoch
        isStale = false
        lastError = nil
        publishSynchronization()
        if invalidationEpoch > startEpoch {
            // Events arrived while this request was in flight. The reply is
            // shown, but not called current: read again after a short pause.
            scheduleResync(delay: resyncDelay)
        }
    }

    /// Store-owned context seam. Composition binds session and connection
    /// publishers here; views must not create their own observation tasks.
    /// A changed session or connection cancels the in-flight request, clears
    /// the display immediately (no cross-context persistence), and starts a
    /// fresh snapshot when the new context is usable (waiting for stream
    /// readiness first when `awaitsEventStream`). Unchanged context is a
    /// no-op (no duplicate transport).
    func contextChanged() {
        let session = activeSessionID()
        let connection = connectionGeneration()
        guard session != observedSessionID || connection != observedConnection else { return }
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelResyncTimer()
        resetContext()
        isLoading = false
        observedSessionID = session
        observedConnection = connection
        guard let session, let connection else {
            publishSynchronization()
            return
        }
        if isRemoved(session, connection) || (awaitsEventStream && readyConnection != connection) {
            publishSynchronization()
            return
        }
        refresh()
    }

    // MARK: - Events

    /// Application event fanout input. Signals for any other connection
    /// generation are ignored. Never mutates records from event payloads;
    /// events only invalidate, tombstone, or mark the stream state.
    func receive(_ signal: ConnectionEventSignal) {
        guard let connection = connectionGeneration(), signal.generation == connection else { return }
        // The observer hop for session/connection changes may lag the stream.
        contextChanged()
        switch signal {
        case .connected:
            readyConnection = connection
            failedConnection = nil
            // A snapshot requested before readiness cannot be proven to
            // include changes published after the subscriber registered.
            invalidateActiveSession(delay: .zero)
        case .failed:
            failedConnection = connection
            readyConnection = nil
            publishSynchronization()
        case .event(_, let envelope):
            apply(SessionEventRouter.route(envelope))
        }
    }

    private func apply(_ route: SessionEventRoute) {
        guard let active = activeSessionID() else { return }
        switch route {
        case .ignored:
            return
        case .historyChanged(let session):
            guard session == active else { return }
            invalidateActiveSession(delay: resyncDelay)
        case .messagesRemoved(let session, let boundary):
            guard session == active else { return }
            applyRemoval(boundary: boundary)
        case .sessionDeleted(let session):
            guard session == active else { return }
            markSessionRemoved(session)
        case .unroutable:
            // Unknown routing triggers a refresh, never a guess.
            invalidateActiveSession(delay: resyncDelay)
        }
    }

    private func invalidateActiveSession(delay: Duration) {
        guard let session = activeSessionID(), let connection = connectionGeneration(),
              !isRemoved(session, connection) else {
            publishSynchronization()
            return
        }
        invalidationEpoch &+= 1
        // An in-flight request completes under an older epoch and follows up;
        // it is never cancelled by events, so a steady stream cannot starve it.
        scheduleResync(delay: delay)
        publishSynchronization()
    }

    private func applyRemoval(boundary: String?) {
        guard let session = activeSessionID(), let connection = connectionGeneration(),
              !isRemoved(session, connection) else { return }
        invalidationEpoch &+= 1
        removalEpoch = invalidationEpoch
        if let boundary {
            if !revertBoundaries.contains(boundary) {
                revertBoundaries.append(boundary)
                if revertBoundaries.count > Self.maximumRevertBoundaries { revertBoundaries.removeFirst() }
            }
            // The projector deletes the boundary and every later record. If
            // the boundary is displayed, drop it and everything after. If not,
            // the display cannot be proven either way: it stays, marked
            // resyncing, until a post-removal snapshot replaces it.
            if let index = messages.firstIndex(where: { $0.messageID == boundary }) {
                for removed in messages[index...] {
                    if let id = removed.messageID { rememberRemoved(id) }
                }
                messages = Array(messages[..<index])
            }
        }
        scheduleResync(delay: .zero)
        publishSynchronization()
    }

    private func markSessionRemoved(_ session: SessionID) {
        guard let connection = connectionGeneration() else { return }
        removedSession = (session, connection)
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelResyncTimer()
        isLoading = false
        messages = []
        publishedSessionID = nil
        publishedConnection = nil
        publishedEpoch = nil
        isStale = false
        lastError = nil
        publishSynchronization()
    }

    // MARK: - Scheduling

    /// Coalesced follow-up snapshot. Deferred until stream readiness when the
    /// store awaits an event stream, and skipped while a request is in flight
    /// (its completion decides whether to follow up).
    private func scheduleResync(delay: Duration) {
        guard let session = activeSessionID(), let connection = connectionGeneration(),
              !isRemoved(session, connection) else { return }
        guard !awaitsEventStream || readyConnection == connection else { return }
        guard !isLoading, resyncTask == nil else { return }
        resyncTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.resyncTask = nil
            guard self.isCurrent(session, connection), !self.isRemoved(session, connection), !self.isLoading else { return }
            self.startSnapshot(session: session, connection: connection, query: .defaultPage)
        }
    }

    private func cancelResyncTimer() {
        resyncTask?.cancel()
        resyncTask = nil
    }

    // MARK: - Helpers

    private func isCurrent(_ session: SessionID, _ connection: UInt64) -> Bool {
        activeSessionID() == session && connectionGeneration() == connection
    }

    private func isRemoved(_ session: SessionID, _ connection: UInt64) -> Bool {
        guard let removedSession else { return false }
        return removedSession.session == session && removedSession.connection == connection
    }

    private func resetContext() {
        messages = []
        publishedSessionID = nil
        publishedConnection = nil
        publishedEpoch = nil
        isStale = false
        lastError = nil
        invalidationEpoch = 0
        removalEpoch = 0
        removedMessageIDs = []
        revertBoundaries = []
        if let removedSession, removedSession.connection != connectionGeneration() {
            self.removedSession = nil
        }
    }

    private func rememberRemoved(_ id: String) {
        guard !removedMessageIDs.contains(id) else { return }
        removedMessageIDs.append(id)
        if removedMessageIDs.count > Self.maximumRemovedMessageIDs { removedMessageIDs.removeFirst() }
    }

    /// Deleted records never return: truncate at any tombstoned boundary the
    /// snapshot still contains, and drop individually removed ids.
    private func applyingTombstones(to list: [TranscriptMessage]) -> [TranscriptMessage] {
        var result = list
        for boundary in revertBoundaries {
            if let index = result.firstIndex(where: { $0.messageID == boundary }) {
                result = Array(result[..<index])
            }
        }
        if !removedMessageIDs.isEmpty {
            let removed = Set(removedMessageIDs)
            result.removeAll { message in message.messageID.map(removed.contains) ?? false }
        }
        return result
    }

    private func publishSynchronization() {
        let next = computeSynchronization()
        if next != synchronization { synchronization = next }
    }

    private func computeSynchronization() -> TranscriptSynchronization {
        guard let session = activeSessionID(), let connection = connectionGeneration() else { return .unavailable }
        if isRemoved(session, connection) { return .sessionRemoved }
        if lastError != nil { return .refreshFailed }
        if failedConnection == connection { return .streamLost }
        guard let publishedEpoch else {
            if isLoading { return .hydrating }
            return (awaitsEventStream && readyConnection != connection) ? .awaitingStream : .hydrating
        }
        guard readyConnection == connection else { return .snapshotOnly }
        return publishedEpoch < invalidationEpoch ? .resyncing : .live
    }

    /// Chronological presentation without inventing order: the default
    /// newest-first page is reversed exactly once; any other server order is
    /// kept directly. Never sorted by timestamp.
    private static func presented(
        serverOrdered: [TranscriptMessage],
        query: TranscriptQuery
    ) -> [TranscriptMessage] {
        if query.order == .desc {
            return Array(serverOrdered.reversed())
        }
        return serverOrdered
    }
}
