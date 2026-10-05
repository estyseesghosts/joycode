import Combine
import Foundation

/// R10 permission approvals: authoritative pending list plus user replies,
/// reconciled honestly without inventing settlement or order.
///
/// Pinned OpenCode v2.0.20 (`docs/plan/r08-r11-contract-preparation-2026-10-05.md`,
/// `API/Permission/PermissionAPI.swift`, `docs/v2_contract.md`):
/// - `GET /api/session/{id}/permission` -> `200 {data: Permission.Request[]}`:
///   pending-only list owned by the session. A `Permission.Request` requires
///   `id`, `sessionID`, `action`, `resources: string[]`; `save`, `metadata`,
///   tool `source`, and `message` are optional.
/// - `POST /api/session/{id}/permission/{requestID}/reply` body
///   `{decision: "once"|"always"|"reject", message?}` -> `204`: the reply is
///   accepted, not proof of settlement. Declared errors are `400`/`401`/`404`
///   (a missing, repeated, or wrong-session reply is `404`); there is no
///   declared `409`. No positive settled permission detail remains.
/// - Public events are `permission.asked` (Request.fields includes ID) and
///   `permission.replied` (`{sessionID, requestID, reply}`).
///
/// Reconciliation rules (R10 store slice):
/// - The pending list is written only by scoped session reads. Events
///   (`permission.asked` / `permission.replied`) only invalidate the list;
///   they are never merged into it and never remove from it. Removal happens
///   only when a fresh read no longer contains the id.
/// - P1 UI policy admits only `once` / `reject` (`PermissionChoice`). The wire
///   `always` case (`PermissionDecision`) needs a separate policy disposition
///   and is never offered here.
/// - Every reply rereads the list, whatever the transport outcome
///   (`accepted`, `notFound`, `rejected`, `unknown`). A `404` is reported as
///   an honest missing request, never as success. A lost reply (`unknown`)
///   keeps its ambiguity even when the reread no longer lists the id
///   (absence is not success) and never re-POSTs.
/// - Taps are suppressed while a reply is in flight, while an accepted reply
///   awaits its confirming read, and while a reply outcome is unknown.
/// - Stream failure retains facts, marks them stale, and disables approval;
///   it never claims settlement. Recovery is R13.
/// - Local epochs discard overlapping reads (newest request wins) and stale
///   reply completions, including A-B-A context returns. One coalesced
///   follow-up read runs when events arrived mid-flight. Request ids dedupe
///   within a read; no `seq` ordering is assumed or used.
///
/// API independence: transport mapping (HTTP shapes, declared rejection vs
/// unknown) lives in the injected closures (see `ConversationComposition` and
/// `PermissionAPI`); this store only consumes `[PermissionRequest]` lists and
/// `PermissionReplyOutcome` values.

// MARK: - Store-owned value types

/// P1 reply choice offered by the UI. `always` is deliberately absent: P1
/// exposes no permanent auto-approval. The composition adapter maps this to
/// the wire `PermissionDecision` (`once`/`reject`).
enum PermissionChoice: String, Equatable, Sendable {
    case once
    case reject
}

/// Reply transport outcome, produced by the composition-owned adapter.
/// `accepted` mirrors `204` (accepted, not settlement proof); `notFound`
/// mirrors declared `404` (honest missing, never success); `rejected` covers
/// declared rejections (`400`/`401`); `unknown` covers lost replies and
/// cancellation (never evidence of rejection or success, never retried).
enum PermissionReplyOutcome: Equatable, Sendable {
    case accepted
    case notFound
    case rejected
    case unknown
}

/// Where the pending list came from: the active session and connection it was
/// read under, plus the completed read epoch. Displayed approvals never mix
/// facts across sessions or generations.
struct PermissionProvenance: Equatable, Sendable {
    let session: SessionID
    let generation: UInt64
    let readEpoch: UInt64
}

// MARK: - Store

/// Pending permission approvals for the active session, fed by scoped list
/// reads and the application event fanout. See the file header for the
/// reconciliation contract. Composition owns all bindings via
/// `contextSubscriptions` and `eventObservation`; views read only the
/// published facts and the `canReply(_:)` approval contract.
@MainActor final class PermissionStore: ObservableObject {
    /// Authoritative pending list from the latest completed scoped read
    /// (`[]` before the first read or after a context reset). The only source
    /// that may claim pending membership; events never write it.
    @Published private(set) var pending: [PermissionRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    @Published private(set) var provenance: PermissionProvenance?
    /// Last reply notice (rejected reply, honest missing request). Cleared on
    /// the next reply tap or context reset; a confirming read never clears it
    /// (the notice must survive the reread it triggered).
    @Published private(set) var lastError: String?
    /// True while at least one request is pending.
    var hasPending: Bool { !pending.isEmpty }

    /// Whether a reply tap for `requestID` may be issued now. True only with
    /// a usable context, a live stream, the id in the authoritative list, and
    /// no uncertain reply state for the id (in flight, accepted awaiting its
    /// confirming read, or lost-reply ambiguity). Silence is never approval.
    func canReply(_ requestID: String) -> Bool {
        guard let session = activeSessionID(), let generation = connectionGeneration(),
              provenance?.session == session, provenance?.generation == generation else { return false }
        guard !isStale else { return false }
        guard pending.contains(where: { $0.id == requestID }) else { return false }
        guard !replying.contains(requestID),
              !awaitingRead.contains(requestID),
              !unknownReplies.contains(requestID) else { return false }
        return true
    }

    /// True while a reply for `requestID` is on the wire.
    func isReplying(_ requestID: String) -> Bool { replying.contains(requestID) }

    /// True when the reply for `requestID` was lost. The ambiguity is retained
    /// even if the reread no longer lists the id; the request is never
    /// re-POSTed automatically.
    func hasUnknownReply(_ requestID: String) -> Bool { unknownReplies.contains(requestID) }

    /// Human-readable notice while any lost-reply ambiguity is retained.
    var attentionReason: String? {
        unknownReplies.isEmpty ? nil
            : "A permission reply was lost. Refresh to reconcile; the request is not retried automatically."
    }

    private let activeSessionID: @MainActor () -> SessionID?
    private let connectionGeneration: @MainActor () -> UInt64?
    private let loadPending: @MainActor @Sendable (SessionID) async throws -> [PermissionRequest]
    private let replyAction: @MainActor @Sendable (SessionID, String, PermissionChoice) async -> PermissionReplyOutcome

    private var requestGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var replyTasks: [String: Task<Void, Never>] = [:]
    private var observedSessionID: SessionID?
    private var observedConnection: UInt64?
    var contextSubscriptions = Set<AnyCancellable>()
    /// Composition-owned observation of the application event fanout.
    var eventObservation: ConnectionEventObservation?

    // Local epochs and clocks. None of these are server facts.
    private var invalidationEpoch: UInt64 = 0
    private var readEpoch: UInt64 = 0
    private var contextEpoch: UInt64 = 0

    // Per-request reply state. `replying` is in-flight transport;
    // `awaitingRead` follows an accepted reply until the confirming read;
    // `unknownReplies` retains lost-reply ambiguity across reads.
    @Published private var replying: Set<String> = []
    @Published private var awaitingRead: Set<String> = []
    @Published private var unknownReplies: Set<String> = []

    // Stream knowledge for the observed connection. Set only by fanout
    // signals on the current generation; never by silence.
    private var streamFailed = false
    private var readStale = false

    // Duplicate suppression for fanout envelopes. No `seq` ordering is
    // assumed: permission events are deduplicated by bounded ID window only.
    private var recentEventIDs: [String] = []
    private var recentEventIDSet: Set<String> = []
    private static let maximumRecentEventIDs = 256

    init(
        activeSessionID: @escaping @MainActor () -> SessionID?,
        connectionGeneration: @escaping @MainActor () -> UInt64?,
        load: @escaping @MainActor @Sendable (SessionID) async throws -> [PermissionRequest],
        reply: @escaping @MainActor @Sendable (SessionID, String, PermissionChoice) async -> PermissionReplyOutcome
    ) {
        self.activeSessionID = activeSessionID
        self.connectionGeneration = connectionGeneration
        self.loadPending = load
        self.replyAction = reply
    }

    // MARK: - Pending-list reads

    /// Explicit scoped reread of the session-owned pending list. Always
    /// allowed, including while a reply is uncertain: it reconciles, it never
    /// re-POSTs. Supersedes any in-flight read; overlapping completions
    /// publish only on an exact match of request generation, session, and
    /// connection generation.
    func refresh() {
        let session = activeSessionID()
        let connection = connectionGeneration()
        if session != observedSessionID || connection != observedConnection {
            resetForContext(session: session, connection: connection)
        }
        observedSessionID = session
        observedConnection = connection
        startLoad()
    }

    private func startLoad() {
        guard let session = activeSessionID(), let connection = connectionGeneration() else {
            // Nil context disables transport: no request is dispatched.
            requestGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            publish()
            return
        }
        requestGeneration &+= 1
        let attempt = requestGeneration
        let startEpoch = invalidationEpoch
        loadTask?.cancel()
        isLoading = true
        publish()
        let work = loadPending
        loadTask = Task { @MainActor [weak self] in
            guard let self, self.requestGeneration == attempt else { return }
            guard self.isCurrent(session, connection) else { return }
            do {
                let members = try await work(session)
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                self.publishLoad(
                    members: members,
                    session: session,
                    connection: connection,
                    startEpoch: startEpoch
                )
            } catch is CancellationError {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                self.isLoading = false
                self.readStale = true
                self.publish()
            } catch {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                // Same-context failure retains facts, marked stale. It never
                // claims settlement.
                self.isLoading = false
                self.readStale = true
                self.publish()
            }
        }
    }

    private func publishLoad(
        members: [PermissionRequest],
        session: SessionID,
        connection: UInt64,
        startEpoch: UInt64
    ) {
        isLoading = false
        // Fail-closed attribution: every entry must belong to the session that
        // was read. One unattributable entry fails the whole read rather than
        // surfacing (or silently dropping) a pending approval.
        guard members.allSatisfy({ PermissionAPI.isAttributable($0, sessionID: session, requestID: nil) }) else {
            readStale = true
            publish()
            if invalidationEpoch > startEpoch, isCurrent(session, connection) {
                startLoad()
            }
            return
        }
        readEpoch &+= 1
        pending = Self.deduplicated(members)
        provenance = PermissionProvenance(session: session, generation: connection, readEpoch: readEpoch)
        readStale = false
        // The authoritative list reconciles accepted replies. Lost-reply
        // ambiguity is deliberately retained: absence is not success.
        awaitingRead.removeAll()
        publish()
        if invalidationEpoch > startEpoch, isCurrent(session, connection) {
            // Events arrived while this request was in flight. The reply
            // stands, but it is not current: follow up once (completion
            // re-checks, so a steady stream converges instead of starving).
            startLoad()
        }
    }

    /// Store-owned context seam. Composition binds session and connection
    /// publishers here; views must not create their own observation tasks. A
    /// changed session or connection cancels in-flight loads and reply tasks,
    /// clears per-context facts immediately, and starts a fresh read when the
    /// new context is usable. Unchanged context is a no-op (no duplicate
    /// transport).
    func contextChanged() {
        let session = activeSessionID()
        let connection = connectionGeneration()
        guard session != observedSessionID || connection != observedConnection else { return }
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        refresh()
    }

    // MARK: - Replies

    /// Replies to one pending request. Synchronous for the Button-bound view
    /// contract: the transport runs in a follow-up task. No-op without a
    /// usable context, while the id is already uncertain (in flight, accepted
    /// awaiting its confirming read, or lost-reply ambiguity), or when the id
    /// is not in the authoritative list. Sends at most one transport call per
    /// accepted tap; a lost reply never re-POSTs.
    func reply(requestID: String, decision: PermissionChoice) {
        contextChanged()
        guard canReply(requestID) else { return }
        guard let session = activeSessionID(), let connection = connectionGeneration() else { return }
        // Capture the originating context before the queued transport runs; a
        // context move in between must drop the stale completion.
        let epoch = contextEpoch
        replying.insert(requestID)
        lastError = nil
        publish()
        let work = replyAction
        replyTasks[requestID]?.cancel()
        replyTasks[requestID] = Task { @MainActor [weak self] in
            await self?.performReply(
                session: session,
                connection: connection,
                epoch: epoch,
                requestID: requestID,
                decision: decision,
                work: work
            )
        }
    }

    private func performReply(
        session: SessionID,
        connection: UInt64,
        epoch: UInt64,
        requestID: String,
        decision: PermissionChoice,
        work: @MainActor @Sendable (SessionID, String, PermissionChoice) async -> PermissionReplyOutcome
    ) async {
        guard isCurrent(session, connection, epoch) else {
            // The context moved while the request was queued. The reset
            // already cleared the reply state; never dispatch for a session or
            // generation this store no longer observes.
            return
        }
        let outcome = await work(session, requestID, decision)
        guard isCurrent(session, connection, epoch) else { return }
        replyTasks[requestID] = nil
        replying.remove(requestID)
        switch outcome {
        case .accepted:
            // Accepted is not settlement proof: suppress further taps until
            // the confirming read reconciles the authoritative list.
            awaitingRead.insert(requestID)
        case .notFound:
            // Honest missing: the request is not pending. Report it, never
            // claim the intended reply succeeded.
            lastError = "The request is no longer pending."
        case .rejected:
            lastError = "The reply was rejected."
        case .unknown:
            // Lost reply: unknown outcome, never an automatic re-POST. The
            // ambiguity is retained across rereads, even when the id is
            // absent from the list.
            unknownReplies.insert(requestID)
        }
        // A read already in flight may predate this reply. Supersede it so
        // only a read begun after the reply can release duplicate suppression.
        invalidationEpoch &+= 1
        refresh()
    }

    // MARK: - Events

    /// Application event fanout input. Signals for any other connection
    /// generation are ignored. Permission events only invalidate the pending
    /// list; they never merge into it and never remove from it.
    func receive(_ signal: ConnectionEventSignal) {
        guard let connection = connectionGeneration(), signal.generation == connection else { return }
        // The observer hop for session/connection changes may lag the stream.
        contextChanged()
        switch signal {
        case .connected:
            // Readiness marker only: no watermark is carried, so anything read
            // before it is re-read rather than trusted.
            invalidationEpoch &+= 1
            publish()
            if !isLoading { startLoad() }
        case .failed:
            // Live-only delivery ended or failed; later changes may have been
            // missed. Retain facts, surface stale, disable approval, and never
            // claim settlement. Recovery is R13.
            streamFailed = true
            publish()
        case .event(_, let envelope):
            applyEnvelope(envelope, connection: connection)
        }
    }

    /// Permission event families this store reconciles. Every other event is
    /// another store's concern and never touches permission facts.
    private static let trackedEventTypes: Set<String> = [
        "permission.asked",
        "permission.replied",
    ]

    private func applyEnvelope(_ envelope: EventEnvelope, connection: UInt64) {
        guard admit(envelope) else { return }
        guard Self.trackedEventTypes.contains(envelope.type) else { return }
        guard let session = activeSessionID() else { return }
        guard let eventSession = Self.sessionRawID(in: envelope.data), !eventSession.isEmpty else {
            // A recognized permission event we cannot attribute to any
            // session cannot be applied. Reconcile rather than guess or
            // silently retain a possibly stale list.
            noteInvalidation()
            return
        }
        guard eventSession == session.rawValue else {
            // Only the active session's approvals are tracked.
            return
        }
        // The event payload is never merged and never removes: only the
        // authoritative read may change the pending list.
        noteInvalidation()
    }

    /// Coalesced follow-up read. Skipped while a request is in flight (its
    /// completion decides whether to follow up).
    private func noteInvalidation() {
        invalidationEpoch &+= 1
        publish()
        if !isLoading { startLoad() }
    }

    /// Duplicate suppression by bounded envelope-ID window. Durable `seq` is
    /// deliberately not used: no ordering across permission events is assumed.
    private func admit(_ envelope: EventEnvelope) -> Bool {
        guard !recentEventIDSet.contains(envelope.id) else { return false }
        recentEventIDSet.insert(envelope.id)
        recentEventIDs.append(envelope.id)
        if recentEventIDs.count > Self.maximumRecentEventIDs {
            let overflow = recentEventIDs.count - Self.maximumRecentEventIDs
            for id in recentEventIDs.prefix(overflow) { recentEventIDSet.remove(id) }
            recentEventIDs.removeFirst(overflow)
        }
        return true
    }

    // MARK: - Helpers

    private func isCurrent(_ session: SessionID, _ connection: UInt64) -> Bool {
        activeSessionID() == session && connectionGeneration() == connection
    }

    private func isCurrent(_ session: SessionID, _ connection: UInt64, _ epoch: UInt64) -> Bool {
        isCurrent(session, connection) && contextEpoch == epoch
    }

    private func resetForContext(session: SessionID?, connection: UInt64?) {
        contextEpoch &+= 1
        loadTask?.cancel()
        loadTask = nil
        for task in replyTasks.values { task.cancel() }
        replyTasks = [:]
        pending = []
        provenance = nil
        replying = []
        awaitingRead = []
        unknownReplies = []
        lastError = nil
        readStale = false
        invalidationEpoch = 0
        if connection != observedConnection {
            streamFailed = false
            recentEventIDs = []
            recentEventIDSet = []
        }
    }

    private func publish() {
        let stale = readStale || streamFailed
        if stale != isStale { isStale = stale }
    }

    private static func deduplicated(_ members: [PermissionRequest]) -> [PermissionRequest] {
        var seen = Set<String>()
        return members.filter { seen.insert($0.id).inserted }
    }

    private static func sessionRawID(in data: EventJSONValue) -> String? {
        guard case .object(let fields) = data,
              case .string(let raw) = fields["sessionID"] else { return nil }
        return raw
    }
}
