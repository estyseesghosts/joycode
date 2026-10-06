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
/// most recent 50 records, kept current by tiered live reconciliation (H08).
///
/// Pinned OpenCode v2.0.20 (`GET /api/session/{id}/message` -> `200
/// {data: Session.Message.Info[], cursor}`; history defaults to 50
/// newest-first, limits 1...200, server page order is authoritative internal
/// sequence, not timestamp; see `docs/plan/r06-r07-contract-notes-2026-10-05.md`
/// and `docs/plan/r08-live-reconciliation-2026-10-05.md`).
///
/// Reconciliation model (H08 tiers). Every event is decoded first
/// (`SessionTranscriptEventDecoder.decode`):
/// - Decoder-covered assistant/tool lifecycle events project locally through
///   the durable reducer (`TranscriptLiveReducer`) and the ephemeral overlay
///   (a per-session `TranscriptLivePublisher`): applied locally when a stable
///   baseline exists, one coalesced `GET .../message/{messageID}` when
///   prerequisites are missing, one debounced page read when structure is
///   unknown, ignored when ephemerally irrelevant.
/// - Anything else follows the structural route (revert tombstone+truncation+
///   full reconcile, session deletion, unknown/unroutable families and
///   shell/compaction/instructions/execution terminal rows -> full
///   invalidation, exactly one debounced page read per burst).
///
/// Hydration rule: events are never buffered or replayed over a page, and the
/// public event stream has no replay or total order, so there is no event
/// sequence comparable with snapshot sequence. A durable event applies
/// locally only when `canApplyLocally` holds: a snapshot is published for
/// this exact session+connection context (`publishedEpoch != nil` with
/// matching `publishedSessionID`/`publishedConnection`), the connection is
/// stream-ready, no snapshot request is in flight (`!isLoading`), and the
/// session is not removed. Otherwise the event is NOT applied; the store
/// invalidates instead, so the in-flight/future snapshot stays non-current
/// under the existing epoch mechanism (this includes events arriving before
/// the first published snapshot: there is no baseline to project onto).
/// Ephemeral overlay handling continues regardless of the hydration gate.
/// Local application never touches `publishedEpoch`/`startEpoch`/
/// `requestGeneration`, so a stale snapshot reply is still discarded or
/// published as resyncing by the existing logic.
///
/// Targeted reads coalesce per message: twenty synchronous events for one id
/// yield one outstanding `GET .../message/{id}` (scheduled absorbs; in-flight
/// marks dirty for exactly one re-read; three consecutive dirty discards
/// escalate to one full invalidation). A response merges only onto a live
/// baseline (token, session+connection, removal, and baseline checks); it
/// replaces its row in place without moving anything else, or escalates to
/// one page reconciliation when absent from the window. Any failure --
/// including `404 notFound`, which means the server no longer holds the
/// message and the window cannot be trusted -- removes the entry (never
/// wedged) and escalates to one full reconciliation.
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
    @Published private(set) var messages: [TranscriptMessage] = [] {
        didSet { rebuildPresentation() }
    }
    /// Latest flushed ephemeral overlay snapshot, in global start order.
    /// Fed from the per-session publisher; never reconstructed in the view.
    @Published private(set) var liveItems: [TranscriptLiveItem] = [] {
        didSet { rebuildPresentation() }
    }
    /// Store-owned presentation model: persisted rows with stable identity
    /// plus their live overlay items. The view iterates this directly.
    @Published private(set) var presentationRows: [TranscriptPresentationRow] = []
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
    private let loadMessage: @MainActor @Sendable (SessionID, String) async throws -> TranscriptMessage
    private let liveFlushScheduler: TranscriptLiveFlushScheduler
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

    // Per-message targeted-read coalescing. At most one outstanding read per
    // id: `scheduled` absorbs synchronous duplicates without marking dirty
    // (the loader has not been called yet), `inFlight` marks dirty for exactly
    // one re-read, and repeated dirty discards escalate to a page read.
    private struct MessageReadEntry {
        var token: UInt64
        var task: Task<Void, Never>?
        var inFlight: Bool
        var dirty: Bool
        var discards: Int
    }

    private var messageReads: [String: MessageReadEntry] = [:]
    private var messageReadToken: UInt64 = 0
    /// Three consecutive dirty discards escalate to one full invalidation.
    private static let maximumMessageReadDiscards = 3

    // Durable stream-settlement bookkeeping: the ordinal of the most recent
    // started slot whose empty item the store itself appended, per
    // (assistant message, text/reasoning kind). Only an entry-matching
    // terminal may settle locally (the projector's "latest" target is then
    // unambiguous); anything else reconciles via a targeted read. Ordinals
    // are never equated with content indices.
    private struct AppliedStartKey: Hashable {
        var messageID: String
        var kind: TranscriptStreamKind
    }

    private var appliedStarts: [AppliedStartKey: Int] = [:]

    // Ephemeral overlay ownership: one publisher per active session (its
    // `activeSession` is fixed at init). `inflightEvent` stashes the event
    // being applied around `publisher.receive(_:)` because `onOutcome` does
    // not receive it; the handler needs kind/ordinal/messageID.
    private var livePublisher: TranscriptLivePublisher?
    private var livePublisherSession: SessionID?
    private var livePublisherSink: AnyCancellable?
    private var inflightEvent: SessionTranscriptEvent?

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
        load: @escaping @MainActor @Sendable (SessionID, TranscriptQuery) async throws -> TranscriptPage,
        loadMessage: @escaping @MainActor @Sendable (SessionID, String) async throws -> TranscriptMessage = { _, _ in throw TranscriptAPIError.notConnected },
        liveFlushScheduler: TranscriptLiveFlushScheduler = TaskFlushScheduler()
    ) {
        self.activeSessionID = activeSessionID
        self.connectionGeneration = connectionGeneration
        self.awaitsEventStream = awaitsEventStream
        self.resyncDelay = resyncDelay
        self.loadPage = load
        self.loadMessage = loadMessage
        self.liveFlushScheduler = liveFlushScheduler
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
        // A snapshot replaces the baseline the store projected onto: the
        // ordinal-to-content mapping for earlier starts is unknowable, so
        // later terminals reconcile via targeted reads.
        appliedStarts.removeAll()
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
    /// generation are ignored. Decoder-covered assistant/tool lifecycle
    /// events project through the durable reducer and the ephemeral overlay;
    /// everything else follows the structural route (revert, deletion,
    /// unknown/unroutable and uncovered structural families).
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
            receiveEnvelope(envelope)
        }
    }

    /// Tiered dispatch: decode first, then project, reconcile, or ignore.
    private func receiveEnvelope(_ envelope: EventEnvelope) {
        guard let active = activeSessionID() else { return }
        switch SessionTranscriptEventDecoder.decode(envelope) {
        case .notApplicable:
            apply(SessionEventRouter.structuralRoute(envelope))
        case .malformed(let session, let assistantMessageID):
            receiveMalformed(session: session, assistantMessageID: assistantMessageID, active: active)
        case .event(let event):
            receiveLiveEvent(event, active: active)
        }
    }

    /// Recognized type with missing or ill-typed fields: never mutate, never
    /// guess. Unattributable events refresh (as unroutable today); other-
    /// session events are ignored; an attributed assistant id reconciles that
    /// single message, otherwise the page reconciles.
    private func receiveMalformed(session: SessionID?, assistantMessageID: String?, active: SessionID) {
        guard let session else {
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        guard session == active else { return }
        guard let assistantMessageID, !assistantMessageID.isEmpty else {
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        requestMessageRefresh(assistantMessageID)
    }

    /// Durable reducer first, then the ephemeral overlay. The reducer is
    /// skipped for families it ignores anyway (deltas, progress, streamed
    /// markers, text/reasoning starts) and for text/reasoning terminals,
    /// whose reducer outcome is always a refresh request: the overlay outcome
    /// decides settlement there instead.
    private func receiveLiveEvent(_ event: SessionTranscriptEvent, active: SessionID) {
        guard event.sessionID == active else { return }
        if event.clearsStreamSettlement {
            appliedStarts.removeValue(forKey: AppliedStartKey(messageID: event.assistantMessageID, kind: .text))
            appliedStarts.removeValue(forKey: AppliedStartKey(messageID: event.assistantMessageID, kind: .reasoning))
        }
        if Self.reducesDurably(event) {
            switch TranscriptLiveReducer.reduce(messages: messages, activeSession: active, event: event) {
            case .applied(let next):
                applyLocalReduction(next)
                markMessageDirtyIfInFlight(event.assistantMessageID)
            case .ignored:
                break
            case .needsMessageRefresh(let messageID):
                requestMessageRefresh(messageID)
            case .needsFullRefresh:
                invalidateActiveSession(delay: resyncDelay)
            }
        }
        ensureLivePublisher(for: active)
        inflightEvent = event
        livePublisher?.receive(event)
        inflightEvent = nil
    }

    /// Reducer input set: every other decoder-covered family returns
    /// `.ignored` (or a refresh the overlay decides) without durable facts.
    private static func reducesDurably(_ event: SessionTranscriptEvent) -> Bool {
        switch event {
        case .stepStarted, .stepEnded, .stepFailed,
            .toolInputStarted, .toolInputEnded, .toolCalled,
            .toolSuccess, .toolFailed:
            return true
        case .stepStreamed,
            .textStarted, .textDelta, .textEnded,
            .reasoningStarted, .reasoningDelta, .reasoningEnded,
            .toolInputDelta, .toolProgress:
            return false
        }
    }

    /// Publishes a locally reduced projection. Only on a stable baseline
    /// (`canApplyLocally`): without one the event is NOT applied and instead
    /// invalidates the in-flight/future snapshot, which stays non-current
    /// under the epoch mechanism. Tombstone filtering applies when removals
    /// are recorded.
    private func applyLocalReduction(_ next: [TranscriptMessage]) {
        guard canApplyLocally else {
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        let filtered: [TranscriptMessage]
        if removedMessageIDs.isEmpty && revertBoundaries.isEmpty {
            filtered = next
        } else {
            filtered = applyingTombstones(to: next)
        }
        if filtered != messages { messages = filtered }
        publishSynchronization()
    }

    /// A snapshot is published for this exact session+connection context, the
    /// connection is stream-ready, no snapshot request is in flight, and the
    /// session is not removed. Only then may durable events project locally;
    /// otherwise they invalidate. Ephemeral overlay handling is unaffected.
    private var canApplyLocally: Bool {
        guard let session = activeSessionID(), let connection = connectionGeneration() else { return false }
        guard !isRemoved(session, connection) else { return false }
        guard publishedEpoch != nil else { return false }
        guard publishedSessionID == session, publishedConnection == connection else { return false }
        guard readyConnection == connection else { return false }
        guard !isLoading else { return false }
        return true
    }

    // MARK: - Overlay outcomes

    /// Reacts to one overlay outcome for the stashed in-flight event.
    /// `.updated` needs only the publisher's coalesced flush (never a read),
    /// except observed text/reasoning starts, which also append their empty
    /// durable slot. Tool terminals need nothing further (the durable reducer
    /// already handled them); stream terminals settle locally only when the
    /// appended item is unambiguously the projector's target.
    private func handleOverlayOutcome(_ outcome: TranscriptLiveOverlayOutcome) {
        switch outcome {
        case .updated:
            if let event = inflightEvent { applyStreamStart(event) }
        case .settled(let settlement):
            switch settlement {
            case .tool:
                break
            case .stream(let id, let text):
                settleStream(id: id, text: text)
            }
        case .needsMessageRefresh(let messageID):
            requestMessageRefresh(messageID)
        case .ignored:
            break
        }
    }

    /// Records one observed text/reasoning start as its empty durable slot.
    /// Only for new slots (duplicate starts report `.ignored`), only with a
    /// stable baseline, and only when the assistant row exists; otherwise
    /// records nothing and a later terminal reconciles via a targeted read.
    private func applyStreamStart(_ event: SessionTranscriptEvent) {
        let messageID: String
        let ordinal: Int
        let kind: TranscriptStreamKind
        switch event {
        case .textStarted(_, let id, let slot, _):
            messageID = id
            ordinal = slot
            kind = .text
        case .reasoningStarted(_, let id, let slot, _):
            messageID = id
            ordinal = slot
            kind = .reasoning
        default:
            return
        }
        guard canApplyLocally else { return }
        guard let next = TranscriptLiveReducer.appendingEmptyContent(to: messages, messageID: messageID, kind: kind) else { return }
        let filtered: [TranscriptMessage]
        if removedMessageIDs.isEmpty && revertBoundaries.isEmpty {
            filtered = next
        } else {
            filtered = applyingTombstones(to: next)
        }
        if filtered != messages { messages = filtered }
        appliedStarts[AppliedStartKey(messageID: messageID, kind: kind)] = ordinal
        markMessageDirtyIfInFlight(messageID)
        publishSynchronization()
    }

    /// Settles one stream terminal. Applies locally only when the store
    /// appended that slot's empty item and it is still the latest of its
    /// kind (`appliedStarts` match, so the projector's "latest" target equals
    /// it unambiguously): a complete start/end sequence then needs zero
    /// targeted reads. Otherwise issues one coalesced targeted read. Never
    /// equates an ordinal with an index.
    private func settleStream(id: LiveContentID, text: String) {
        let messageID: String
        let ordinal: Int
        let kind: TranscriptStreamKind
        switch id {
        case .text(let id, let value):
            messageID = id
            ordinal = value
            kind = .text
        case .reasoning(let id, let value):
            messageID = id
            ordinal = value
            kind = .reasoning
        case .tool:
            return
        }
        let key = AppliedStartKey(messageID: messageID, kind: kind)
        guard canApplyLocally,
              appliedStarts[key] == ordinal,
              let next = TranscriptLiveReducer.settingLastContentText(in: messages, messageID: messageID, kind: kind, text: text) else {
            requestMessageRefresh(messageID)
            return
        }
        let filtered: [TranscriptMessage]
        if removedMessageIDs.isEmpty && revertBoundaries.isEmpty {
            filtered = next
        } else {
            filtered = applyingTombstones(to: next)
        }
        if filtered != messages { messages = filtered }
        appliedStarts.removeValue(forKey: key)
        markMessageDirtyIfInFlight(messageID)
        publishSynchronization()
    }

    // MARK: - Targeted message reads

    /// One coalesced authoritative read for a single message. Without a
    /// stable baseline there is nothing to merge onto, so the page
    /// reconciles instead. An already-scheduled id absorbs the request; once
    /// in flight it marks dirty for exactly one re-read.
    private func requestMessageRefresh(_ messageID: String) {
        guard canApplyLocally,
              let session = activeSessionID(),
              let connection = connectionGeneration() else {
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        if messageReads[messageID] != nil {
            markMessageDirtyIfInFlight(messageID)
            return
        }
        startMessageRead(session: session, connection: connection, messageID: messageID, discards: 0)
        publishSynchronization()
    }

    /// A durable-affecting event for a message with a read already past its
    /// loader call marks it for exactly one re-read. Ephemeral events never
    /// reach this path, so they never mark dirty.
    private func markMessageDirtyIfInFlight(_ messageID: String) {
        if messageReads[messageID]?.inFlight == true {
            messageReads[messageID]?.dirty = true
        }
    }

    private func startMessageRead(session: SessionID, connection: UInt64, messageID: String, discards: Int) {
        messageReadToken &+= 1
        let token = messageReadToken
        messageReads[messageID] = MessageReadEntry(token: token, task: nil, inFlight: false, dirty: false, discards: discards)
        let work = loadMessage
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            // No suspension between the in-flight mark and the loader call,
            // so synchronous absorbs stay clean while later events mark dirty.
            self.messageReads[messageID]?.inFlight = true
            do {
                let message = try await work(session, messageID)
                self.completeMessageRead(session: session, connection: connection, token: token, messageID: messageID, message: message)
            } catch is CancellationError {
                self.settleMessageReadError(session: session, connection: connection, token: token, messageID: messageID)
            } catch {
                self.settleMessageReadError(session: session, connection: connection, token: token, messageID: messageID)
            }
        }
        messageReads[messageID]?.task = task
    }

    /// Merges one targeted response. Requires the table token, a current and
    /// live request context, and a published baseline; a dirty entry discards
    /// the stale response for exactly one re-read (three consecutive dirty
    /// discards escalate to one full invalidation). A row present in the
    /// window is replaced in place without moving anything else; an absent
    /// message escalates to one page reconciliation rather than inventing
    /// ordering. Tombstoned ids are discarded, never revived.
    private func completeMessageRead(
        session: SessionID,
        connection: UInt64,
        token: UInt64,
        messageID: String,
        message: TranscriptMessage
    ) {
        guard let entry = messageReads[messageID], entry.token == token else { return }
        guard isCurrent(session, connection), !isRemoved(session, connection) else {
            messageReads.removeValue(forKey: messageID)
            publishSynchronization()
            return
        }
        guard publishedEpoch != nil, publishedSessionID == session, publishedConnection == connection else {
            messageReads.removeValue(forKey: messageID)
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        if entry.dirty {
            let discards = entry.discards + 1
            if discards >= Self.maximumMessageReadDiscards {
                messageReads.removeValue(forKey: messageID)
                publishSynchronization()
                invalidateActiveSession(delay: resyncDelay)
            } else {
                startMessageRead(session: session, connection: connection, messageID: messageID, discards: discards)
                publishSynchronization()
            }
            return
        }
        if isTombstoned(messageID) {
            messageReads.removeValue(forKey: messageID)
            publishSynchronization()
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        guard let index = messages.firstIndex(where: { $0.messageID == messageID }) else {
            messageReads.removeValue(forKey: messageID)
            publishSynchronization()
            invalidateActiveSession(delay: resyncDelay)
            return
        }
        var next = messages
        next[index] = message
        if next != messages { messages = next }
        appliedStarts.removeValue(forKey: AppliedStartKey(messageID: messageID, kind: .text))
        appliedStarts.removeValue(forKey: AppliedStartKey(messageID: messageID, kind: .reasoning))
        messageReads.removeValue(forKey: messageID)
        publishSynchronization()
    }

    /// Any targeted-read failure removes the entry (never wedged) and
    /// escalates to one full reconciliation when the context is still
    /// current. `404 notFound` is included deliberately: the server no longer
    /// holds the message (or the session), so the window cannot be trusted
    /// and only a page read re-establishes it; a later event for the same id
    /// starts a fresh entry. Cancellation with current context behaves the
    /// same; cancellation after a context change finds no entry and drops.
    private func settleMessageReadError(session: SessionID, connection: UInt64, token: UInt64, messageID: String) {
        guard let entry = messageReads[messageID], entry.token == token else { return }
        messageReads.removeValue(forKey: messageID)
        guard isCurrent(session, connection), !isRemoved(session, connection) else {
            publishSynchronization()
            return
        }
        invalidateActiveSession(delay: resyncDelay)
    }

    private func cancelMessageReads() {
        for entry in messageReads.values { entry.task?.cancel() }
        messageReads.removeAll()
    }

    private func isTombstoned(_ messageID: String) -> Bool {
        if removedMessageIDs.contains(messageID) { return true }
        return revertBoundaries.contains(messageID)
    }

    // MARK: - Overlay ownership

    /// Lazily creates (or rebuilds, when the session changed) the per-session
    /// publisher and binds its flushed snapshots to `liveItems`.
    private func ensureLivePublisher(for session: SessionID) {
        if livePublisherSession == session, livePublisher != nil { return }
        livePublisherSink?.cancel()
        livePublisherSink = nil
        let publisher = TranscriptLivePublisher(
            activeSession: session,
            scheduler: liveFlushScheduler,
            onOutcome: { [weak self] outcome in self?.handleOverlayOutcome(outcome) }
        )
        livePublisher = publisher
        livePublisherSession = session
        if publisher.liveItems != liveItems { liveItems = publisher.liveItems }
        livePublisherSink = publisher.$liveItems.sink { [weak self] items in
            guard let self else { return }
            if items != self.liveItems { self.liveItems = items }
        }
    }

    /// Drops the publisher, its subscription, and the published overlay
    /// snapshot (context change or session removal).
    private func dropLivePublisher() {
        livePublisherSink?.cancel()
        livePublisherSink = nil
        livePublisher = nil
        livePublisherSession = nil
        if !liveItems.isEmpty { liveItems = [] }
    }

    private func rebuildPresentation() {
        let next = TranscriptPresentation.items(messages: messages, live: liveItems)
        if next != presentationRows { presentationRows = next }
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
        cancelMessageReads()
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
        cancelMessageReads()
        appliedStarts.removeAll()
        dropLivePublisher()
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
        cancelMessageReads()
        appliedStarts.removeAll()
        dropLivePublisher()
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
        // An outstanding targeted read is an event-known change not yet
        // reflected in the published snapshot.
        guard messageReads.isEmpty else { return .resyncing }
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

private extension SessionTranscriptEvent {
    /// Step terminals end stream settlement for their assistant message:
    /// later terminals for cleared slots were never observed with text, so
    /// they reconcile rather than settling into unknown content.
    var clearsStreamSettlement: Bool {
        switch self {
        case .stepEnded, .stepFailed:
            return true
        default:
            return false
        }
    }
}
