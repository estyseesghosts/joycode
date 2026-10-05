import Foundation
import Combine

/// R09 execution status: authoritative running membership plus event-reported
/// outcomes, reconciled honestly without inventing order or completion.
///
/// Pinned OpenCode v2.0.20 (`docs/plan/r08-r11-contract-preparation-2026-10-05.md`,
/// `API/Execution/ExecutionAPI.swift`, `docs/v2_contract.md`):
/// - `GET /api/session/active` -> `200 {data: {[sessionID]: {type: "running"}}}`:
///   process-owned active execution, **including** asynchronous cleanup after a
///   terminal event. There is no `GET /api/session/{id}/status`.
/// - `POST /api/session/{id}/interrupt?resume=false` -> `200 {interrupted: boolean}`:
///   `true` is async acceptance only (cleanup still runs); `false` (for example an
///   idle session) is a valid answer and proves nothing beyond non-acceptance.
///   Silence or disconnect never proves stopped.
/// - `session.status` is an ephemeral event carrying `{sessionID, status: {type}}`
///   liveness; `session.idle` is its deprecated predecessor carrying `{sessionID}`.
///   Terminal outcomes arrive as `session.execution.started/succeeded/failed/
///   interrupted`, with `failed` carrying `{sessionID, error}` and `interrupted`
///   carrying `{sessionID, reason: user|shutdown|superseded|inactivity}`. Retry
///   detail in `session.status` is `{type: "retry", attempt, message, next,
///   action?}` with nonnegative integer `attempt`/`next`.
///
/// Reconciliation rules (R09):
/// - No total order and no event-vs-read order is assumed. `server.connected` is
///   a readiness marker only, never a snapshot watermark. Reads and events write
///   disjoint facts: active-list reads write only running membership; events
///   write only outcome/liveness facts. Neither overwrites the other.
/// - Local epochs discard overlapping active reads (newest request wins) and
///   trigger one coalesced follow-up read when events arrived mid-flight.
/// - Durable `seq` suppresses stale/duplicate deliveries within the same
///   aggregate and connection generation ONLY; it is never ranked against
///   reads. Ephemeral duplicates are suppressed by a bounded recent-ID window.
/// - A terminal event is the last reported outcome, but the active list may
///   still own cleanup: `confirmedStopped` is set only by a fresh inactive
///   read, never by an event alone.
/// - An accepted interrupt waits for confirmation (terminal event received while
///   the request is pending, or a fresh inactive read begun after the reply).
///   A lost reply (`unknown`) never re-POSTs; a later inactive read reconciles
///   to `idle`, never to "interrupted", because a read cannot prove this
///   request caused the stop. Duplicate interrupts are suppressed while a
///   request is requesting/accepted/unknown; explicit `refresh()` stays allowed.
/// - Stream failure or connection replacement surfaces `unknown`/stale and
///   never claims stopped. Failed-generation signals are ignored. Recovery is
///   R13; `blocked` is reserved for R10/R11 pending inputs and is never
///   inferred from retry detail or silence.
///
/// API independence: transport mapping (HTTP shapes, `busy` vs declared
/// rejection vs unknown) lives in the injected closures (see
/// `ConversationComposition.execution` and `ExecutionAPI`); this store only
/// consumes `Set<SessionID>` membership and `ExecutionInterruptReply` values.

// MARK: - Wire-adjacent value types

/// Failure detail reported by `session.execution.failed` (`data.error`).
///
/// Pinned `Session.StructuredError` requires `type` and `message` (optional
/// integer `status` and `response.body` are not displayed). This type is
/// unknown-safe: `type` may be absent, `message` falls back to a stable
/// placeholder, and the raw payload is preserved for debugging without ever
/// being displayed verbatim.
enum SessionError {
    struct Error: Equatable, Sendable, Decodable {
        let type: String?
        let message: String
        let raw: EventJSONValue

        init(type: String?, message: String, raw: EventJSONValue) {
            self.type = type
            self.message = message
            self.raw = raw
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(EventJSONValue.self)
            self.raw = raw
            guard case .object(let fields) = raw else {
                if case .string(let text) = raw, !text.isEmpty {
                    type = nil
                    message = text
                } else {
                    type = nil
                    message = "Execution failed."
                }
                return
            }
            let typeValue: String? = {
                guard case .string(let text) = fields["type"] else { return nil }
                return text
            }()
            let messageValue: String? = {
                guard case .string(let text) = fields["message"], !text.isEmpty else { return nil }
                return text
            }()
            type = typeValue
            message = messageValue ?? "Execution failed."
        }
    }
}

/// Why an execution was interrupted (`data.reason`). Unknown wire values map
/// to `.unknown` rather than failing the event.
enum ExecutionInterruptReason: String, Equatable, Sendable {
    case user
    case shutdown
    case superseded
    case inactivity
    case unknown

    init(wire value: String?) {
        switch value {
        case "user": self = .user
        case "shutdown": self = .shutdown
        case "superseded": self = .superseded
        case "inactivity": self = .inactivity
        default: self = .unknown
        }
    }
}

/// Retry detail from `session.status` (`status.type == "retry"`). Strictly
/// validated: `attempt`/`next` must be nonnegative integers and `message` a
/// string. The pinned optional `action` is a structured object; R09 does not
/// model or display it and tolerates (ignores) it rather than rejecting a
/// valid retry. Malformed payloads are ignored, never coerced, and never
/// surface as `blocked` (R10/R11 own pending inputs).
struct ExecutionRetryDetail: Equatable, Sendable {
    let attempt: Int
    let message: String
    let next: Int
}

/// Liveness hint from `session.status` / deprecated `session.idle`. Ephemeral
/// only: it never proves running membership, which belongs to the active list.
enum ExecutionLiveness: Equatable, Sendable {
    case idle
    case busy
    case retry(ExecutionRetryDetail)
}

/// Last event-reported outcome for the active session. `.started` records that
/// work began; the other cases are terminal reports. A terminal case is the
/// last outcome, not a stop confirmation: confirmation needs a fresh inactive
/// read (`confirmedStopped`).
enum ExecutionOutcome: Equatable, Sendable {
    case started
    case succeeded
    case failed(SessionError.Error)
    case interrupted(ExecutionInterruptReason)
}

/// Interrupt transport outcome, produced by the composition-owned adapter (see
/// `ConversationComposition.execution`). `accepted` mirrors
/// `{interrupted: true}` (async acceptance, not proof of stop);
/// `notInterrupted` mirrors `{interrupted: false}`; `busy` mirrors the
/// conservative undeclared-`409` mapping; `unknown` covers lost replies and
/// cancellation (never evidence of rejection); `failed` covers declared
/// rejections (`400`/`401`/`404`).
enum ExecutionInterruptReply: Equatable, Sendable {
    case accepted
    case notInterrupted
    case busy
    case unknown
    case failed
}

/// Local interrupt request state. `.awaitingConfirmation` follows an accepted
/// reply until a terminal event or a fresh inactive read begun after the reply.
/// `.unknown` follows a lost reply until terminal-event or read evidence; it
/// never re-POSTs and suppresses duplicate requests.
enum ExecutionInterruptState: Equatable, Sendable {
    case idle
    case requesting
    case awaitingConfirmation
    case unknown
}

/// Where one execution fact came from: the active session and connection it was
/// observed under, plus either the completed active-read epoch or the event
/// type/id. Displayed status never mixes facts across sessions or generations.
struct ExecutionFactProvenance: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case activeRead(epoch: UInt64)
        case event(type: String, id: String)
    }

    let session: SessionID
    let generation: UInt64
    let source: Source
}

/// UI attention, stored separately from execution facts so badges and prompts
/// never rewrite the underlying status.
struct ExecutionAttention: Equatable, Sendable {
    var needsAttention = false
    var reason: String?
}

/// Reconciled presentation phase. `.noSession` is the truthful no-selection
/// presentation (no execution context to report on). `.blocked` is reserved for
/// R10/R11 pending inputs: R09 never produces it and never infers it from retry
/// or silence.
enum ExecutionPhase: Equatable, Sendable {
    case noSession
    case idle
    case working
    case completed
    case interrupted(ExecutionInterruptReason)
    case failed
    case blocked
    case unknown
}

// MARK: - Store

/// Execution status for the active session, fed by scoped active-list reads and
/// the application event fanout. See the file header for the reconciliation
/// contract. Composition owns all bindings via `contextSubscriptions` and
/// `eventObservation`; views read only the published facts and the
/// `statusLabel`/`statusReason`/`canInterrupt` presentation contract.
@MainActor final class ExecutionStatusStore: ObservableObject {
    @Published private(set) var phase: ExecutionPhase = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    @Published private(set) var interruptState: ExecutionInterruptState = .idle
    @Published private(set) var lastInterruptError: String?
    @Published private(set) var attention = ExecutionAttention()
    /// Running membership from the latest completed active-list read (`nil`
    /// before the first read or after a context reset). The only source that
    /// may claim membership; events never write it.
    @Published private(set) var isActive: Bool?
    /// Last event-reported outcome (`nil` until the first execution event for
    /// the active session). Events never write membership.
    @Published private(set) var lastOutcome: ExecutionOutcome?
    /// Last validated liveness hint from `session.status` / `session.idle`.
    @Published private(set) var liveness: ExecutionLiveness?
    /// True only after a fresh active-list read excluded the session. Events
    /// alone never set this.
    @Published private(set) var confirmedStopped = false
    @Published private(set) var activeProvenance: ExecutionFactProvenance?
    @Published private(set) var outcomeProvenance: ExecutionFactProvenance?
    @Published private(set) var livenessProvenance: ExecutionFactProvenance?

    /// Presentation label. Pinned values consumed by `ExecutionStatusView` and
    /// UI/composition tests include "No session", "Idle", "Working",
    /// "Interrupted", and "Unknown".
    var statusLabel: String {
        switch phase {
        case .noSession: return "No session"
        case .idle: return "Idle"
        case .working: return "Working"
        case .completed: return "Completed"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .unknown: return "Unknown"
        }
    }

    /// Presentation reason. Always a plain string (never `nil`) for the
    /// `Text`-bound view contract.
    var statusReason: String {
        guard connectionGeneration() != nil else { return "Not connected." }
        guard activeSessionID() != nil else { return "" }
        if streamFailed, !confirmedStopped { return "Event stream lost. Status may be stale." }
        switch phase {
        case .noSession:
            return ""
        case .working:
            if interruptState == .requesting { return "Interrupt requested." }
            if interruptState == .awaitingConfirmation { return "Interrupt accepted. Awaiting confirmation." }
            if isActive == true, let outcome = lastOutcome {
                return "Last reported outcome: \(Self.outcomeNoun(outcome)). Cleanup may still be running."
            }
            if case .retry(let detail) = liveness { return detail.message }
            if readStale { return "Status refresh failed. Showing last known status." }
            return ""
        case .completed:
            if confirmedStopped { return "" }
            return "Reported finished by event. Not yet confirmed by an execution-list read."
        case .interrupted(let reason):
            let base = Self.interruptReasonText(reason)
            return confirmedStopped ? base : base + " Awaiting confirmation."
        case .failed:
            if case .failed(let error) = lastOutcome { return error.message }
            return "Execution failed."
        case .idle:
            if readStale { return "Status refresh failed. Showing last known status." }
            return ""
        case .blocked:
            return "Pending input handling is not supported in R09."
        case .unknown:
            if readStale { return "Status refresh failed. Showing last known status." }
            return "Waiting for execution status."
        }
    }

    /// Whether an interrupt request may be issued now. True only with a usable
    /// context, no stream failure, no request already uncertain or accepted,
    /// and no proof that nothing is running. Silence is not proof of running
    /// either: before the first read the session is assumed possibly running.
    var canInterrupt: Bool {
        guard activeSessionID() != nil, connectionGeneration() != nil else { return false }
        guard !streamFailed, interruptState == .idle else { return false }
        return believedRunning
    }

    private var believedRunning: Bool { isActive ?? true }

    private let activeSessionID: @MainActor () -> SessionID?
    private let connectionGeneration: @MainActor () -> UInt64?
    private let loadActive: @MainActor @Sendable () async throws -> Set<SessionID>
    private let interruptAction: @MainActor @Sendable (SessionID) async -> ExecutionInterruptReply

    private var requestGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var observedSessionID: SessionID?
    private var observedConnection: UInt64?
    var contextSubscriptions = Set<AnyCancellable>()
    /// Composition-owned observation of the application event fanout.
    var eventObservation: ConnectionEventObservation?

    // Local epochs and clocks. None of these are server facts.
    private var invalidationEpoch: UInt64 = 0
    private var readEpoch: UInt64 = 0
    private var clock: UInt64 = 0
    private var requestBeginTick: UInt64 = 0
    private var interruptReplyTick: UInt64 = 0
    private var terminalTick: UInt64 = 0

    // Stream knowledge for the observed connection. Set only by fanout
    // signals on the current generation; never by silence.
    private var streamFailed = false
    private var readStale = false

    // Duplicate suppression. Durable `seq` compares only within one aggregate
    // and generation; ephemeral IDs use a bounded window.
    private var durableSeq: [String: Int] = [:]
    private var recentEventIDs: [String] = []
    private var recentEventIDSet: Set<String> = []
    private static let maximumRecentEventIDs = 256

    init(
        activeSessionID: @escaping @MainActor () -> SessionID?,
        connectionGeneration: @escaping @MainActor () -> UInt64?,
        loadActive: @escaping @MainActor @Sendable () async throws -> Set<SessionID>,
        interrupt: @escaping @MainActor @Sendable (SessionID) async -> ExecutionInterruptReply
    ) {
        self.activeSessionID = activeSessionID
        self.connectionGeneration = connectionGeneration
        self.loadActive = loadActive
        self.interruptAction = interrupt
    }

    // MARK: - Active-list reads

    /// Explicit scoped reread of the process-owned active set. Always allowed,
    /// including while an interrupt request is uncertain: it reconciles, it
    /// never re-POSTs. Supersedes any in-flight read; overlapping completions
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
        startActiveRead()
    }

    private func startActiveRead() {
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
        clock &+= 1
        let beginTick = clock
        let startEpoch = invalidationEpoch
        loadTask?.cancel()
        isLoading = true
        publish()
        let work = loadActive
        loadTask = Task { @MainActor [weak self] in
            guard let self, self.requestGeneration == attempt else { return }
            guard self.isCurrent(session, connection) else { return }
            do {
                let members = try await work()
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                self.publishActiveRead(
                    members: members,
                    session: session,
                    connection: connection,
                    startEpoch: startEpoch,
                    beginTick: beginTick
                )
            } catch is CancellationError {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                self.isLoading = false
                if self.hasFacts { self.readStale = true }
                self.publish()
            } catch {
                guard self.requestGeneration == attempt else { return }
                guard self.isCurrent(session, connection) else { return }
                // Same-context failure retains facts, marked stale. It never
                // claims stopped.
                self.isLoading = false
                self.readStale = true
                self.publish()
            }
        }
    }

    private func publishActiveRead(
        members: Set<SessionID>,
        session: SessionID,
        connection: UInt64,
        startEpoch: UInt64,
        beginTick: UInt64
    ) {
        isLoading = false
        readEpoch &+= 1
        let running = members.contains(session)
        isActive = running
        activeProvenance = ExecutionFactProvenance(
            session: session,
            generation: connection,
            source: .activeRead(epoch: readEpoch)
        )
        readStale = false
        if running {
            confirmedStopped = false
        } else {
            confirmedStopped = true
            // A fresh inactive read begun after an interrupt reply settles the
            // pending request. It reconciles to idle (or the last terminal
            // outcome), never to newly "interrupted": a read cannot prove this
            // request caused the stop.
            if beginTick > interruptReplyTick,
               interruptState == .awaitingConfirmation || interruptState == .unknown {
                interruptState = .idle
            }
        }
        publish()
        if invalidationEpoch > startEpoch, isCurrent(session, connection) {
            // Events arrived while this request was in flight. The reply
            // stands, but it is not current: follow up once (completion
            // re-checks, so a steady stream converges instead of starving).
            startActiveRead()
        }
    }

    /// Store-owned context seam. Composition binds session and connection
    /// publishers here; views must not create their own observation tasks. A
    /// changed session or connection cancels in-flight work, clears
    /// per-context facts immediately, and starts a fresh read when the new
    /// context is usable. Unchanged context is a no-op (no duplicate
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

    // MARK: - Interrupt

    /// Requests interruption of the active session. Synchronous for the
    /// Button-bound view contract: the transport runs in a follow-up task.
    /// No-op without a usable context, while a request is already uncertain or
    /// accepted, or when the session is proven stopped. Sends at most one
    /// transport call per accepted tap; a lost reply never re-POSTs.
    func interrupt() {
        guard let session = activeSessionID(), connectionGeneration() != nil else { return }
        guard interruptState == .idle, canInterrupt else { return }
        clock &+= 1
        requestBeginTick = clock
        interruptState = .requesting
        lastInterruptError = nil
        publish()
        Task { @MainActor [weak self] in
            await self?.performInterrupt(session: session)
        }
    }

    private func performInterrupt(session: SessionID) async {
        guard let connection = connectionGeneration(), isCurrent(session, connection) else {
            // The context moved while the request was queued. The reset
            // already returned the state to idle; never adopt a reply for a
            // session or generation this store no longer observes.
            return
        }
        let reply = await interruptAction(session)
        guard isCurrent(session, connection) else { return }
        clock &+= 1
        interruptReplyTick = clock
        switch reply {
        case .accepted:
            // Acceptance is async: confirmation still needs a terminal event
            // received after the request began, or a fresh inactive read begun
            // after this reply. A terminal event already in hand (delivered
            // inside the interrupt round-trip) confirms immediately.
            interruptState = terminalTick > requestBeginTick ? .idle : .awaitingConfirmation
        case .notInterrupted:
            // `false` is a valid answer (for example an idle session), not an
            // error. Reread to reconcile; it claims no stop.
            interruptState = .idle
        case .busy:
            interruptState = .idle
            lastInterruptError = "Server reported busy."
        case .unknown:
            // Lost reply: unknown outcome, never an automatic re-POST. A
            // scoped reread may still run, but an inactive result reconciles
            // to idle, never to "interrupted".
            interruptState = terminalTick > requestBeginTick ? .idle : .unknown
        case .failed:
            interruptState = .idle
            lastInterruptError = "Interrupt request failed."
        }
        publish()
        noteInvalidation()
    }

    // MARK: - Events

    /// Application event fanout input. Signals for any other connection
    /// generation are ignored. Events update only outcome/liveness facts for
    /// the active session (with per-fact provenance) and invalidate the
    /// membership read; they never write membership and are never ranked
    /// against reads.
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
            if !isLoading { startActiveRead() }
        case .failed:
            // Live-only delivery ended or failed; later changes may have been
            // missed. Surface unknown/stale rather than clearing facts, and
            // never claim stopped. Recovery is R13.
            streamFailed = true
            publish()
        case .event(_, let envelope):
            applyEnvelope(envelope, connection: connection)
        }
    }

    /// Execution/status event families this store reconciles. Every other event
    /// is the transcript router's concern and never touches execution facts.
    private static let trackedEventTypes: Set<String> = [
        "session.execution.started",
        "session.execution.succeeded",
        "session.execution.failed",
        "session.execution.interrupted",
        "session.status",
        "session.idle",
    ]

    private func applyEnvelope(_ envelope: EventEnvelope, connection: UInt64) {
        guard admit(envelope) else { return }
        guard Self.trackedEventTypes.contains(envelope.type) else { return }
        guard let session = activeSessionID() else { return }
        guard let eventSession = Self.sessionID(in: envelope.data) else {
            // A recognized execution/status event we cannot attribute to any
            // session cannot be applied. Reconcile rather than guess or
            // silently retain a possibly stale fact.
            noteInvalidation()
            return
        }
        guard eventSession == session else {
            // Only the active session's execution facts are tracked.
            return
        }
        switch envelope.type {
        case "session.execution.started":
            lastOutcome = .started
            outcomeProvenance = ExecutionFactProvenance(
                session: session, generation: connection, source: .event(type: envelope.type, id: envelope.id)
            )
            confirmedStopped = false
            noteInvalidation()
        case "session.execution.succeeded":
            recordTerminal(.succeeded, envelope: envelope, session: session, connection: connection)
        case "session.execution.failed":
            let error = Self.decodeSessionError(envelope.data)
                ?? SessionError.Error(type: nil, message: "Execution failed.", raw: envelope.data)
            recordTerminal(.failed(error), envelope: envelope, session: session, connection: connection)
        case "session.execution.interrupted":
            recordTerminal(
                .interrupted(ExecutionInterruptReason(wire: Self.reason(in: envelope.data))),
                envelope: envelope,
                session: session,
                connection: connection
            )
        case "session.status":
            guard let liveness = Self.parseLiveness(data: envelope.data, session: session) else {
                // Recognized status we cannot parse: keep prior facts, but
                // reconcile membership rather than silently trusting a stale
                // hint. This never claims stopped.
                noteInvalidation()
                return
            }
            self.liveness = liveness
            livenessProvenance = ExecutionFactProvenance(
                session: session, generation: connection, source: .event(type: envelope.type, id: envelope.id)
            )
            noteInvalidation()
        case "session.idle":
            // Deprecated predecessor of `session.status` idle. Same treatment:
            // an ephemeral hint, confirmed by reread.
            liveness = .idle
            livenessProvenance = ExecutionFactProvenance(
                session: session, generation: connection, source: .event(type: envelope.type, id: envelope.id)
            )
            noteInvalidation()
        default:
            return
        }
        publish()
    }

    /// Records a terminal report: it becomes the last outcome, but stop
    /// confirmation still needs a fresh inactive read, and a pending interrupt
    /// request resolves only when the report arrived after the request began.
    private func recordTerminal(
        _ outcome: ExecutionOutcome,
        envelope: EventEnvelope,
        session: SessionID,
        connection: UInt64
    ) {
        lastOutcome = outcome
        outcomeProvenance = ExecutionFactProvenance(
            session: session, generation: connection, source: .event(type: envelope.type, id: envelope.id)
        )
        clock &+= 1
        terminalTick = clock
        confirmedStopped = false
        if interruptState == .awaitingConfirmation || interruptState == .unknown {
            interruptState = .idle
        }
        noteInvalidation()
    }

    /// Coalesced follow-up read. Skipped while a request is in flight (its
    /// completion decides whether to follow up).
    private func noteInvalidation() {
        invalidationEpoch &+= 1
        publish()
        if !isLoading { startActiveRead() }
    }

    /// Stale/duplicate suppression. Durable `seq` compares only within one
    /// aggregate and connection generation; ephemeral envelopes deduplicate by
    /// bounded ID window. Never ranks an event against a read.
    private func admit(_ envelope: EventEnvelope) -> Bool {
        if let durable = envelope.durable {
            let last = durableSeq[durable.aggregateID] ?? -1
            guard durable.seq > last else { return false }
            durableSeq[durable.aggregateID] = durable.seq
            return true
        }
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

    private var hasFacts: Bool { isActive != nil || lastOutcome != nil || liveness != nil }

    private func isCurrent(_ session: SessionID, _ connection: UInt64) -> Bool {
        activeSessionID() == session && connectionGeneration() == connection
    }

    private func resetForContext(session: SessionID?, connection: UInt64?) {
        isActive = nil
        lastOutcome = nil
        liveness = nil
        activeProvenance = nil
        outcomeProvenance = nil
        livenessProvenance = nil
        confirmedStopped = false
        interruptState = .idle
        lastInterruptError = nil
        readStale = false
        invalidationEpoch = 0
        requestBeginTick = 0
        interruptReplyTick = 0
        terminalTick = 0
        if connection != observedConnection {
            streamFailed = false
            durableSeq = [:]
            recentEventIDs = []
            recentEventIDSet = []
        }
    }

    private func publish() {
        let stale = readStale || streamFailed
        if stale != isStale { isStale = stale }
        let next = computePhase()
        if next != phase { phase = next }
        updateAttention()
    }

    private func computePhase() -> ExecutionPhase {
        // No connection means nothing can be known: unknown, never idle.
        guard connectionGeneration() != nil else { return .unknown }
        // No selected session means there is no execution to report on. This is
        // a truthful no-session presentation, not an idle claim, and
        // `canInterrupt` stays false. Composition/hydration replaces it with a
        // real membership read once a session is selected.
        guard activeSessionID() != nil else { return .noSession }
        if streamFailed, !confirmedStopped { return .unknown }
        if interruptState == .requesting || interruptState == .awaitingConfirmation { return .working }
        if let active = isActive {
            if active { return .working }
            if let outcome = lastOutcome {
                switch outcome {
                case .succeeded: return .completed
                case .failed: return .failed
                case .interrupted(let reason): return .interrupted(reason)
                case .started: return .idle
                }
            }
            return .idle
        }
        if let outcome = lastOutcome {
            switch outcome {
            case .started: return .working
            case .succeeded: return .completed
            case .failed: return .failed
            case .interrupted(let reason): return .interrupted(reason)
            }
        }
        if let liveness {
            switch liveness {
            case .busy, .retry: return .working
            case .idle: return .idle
            }
        }
        return .unknown
    }

    private func updateAttention() {
        if case .failed = phase, case .failed(let error) = lastOutcome {
            attention = ExecutionAttention(needsAttention: true, reason: error.message)
        } else if interruptState == .unknown {
            attention = ExecutionAttention(
                needsAttention: true,
                reason: "Interrupt reply was lost. Refresh to reconcile; the request is not retried automatically."
            )
        } else {
            attention = ExecutionAttention()
        }
    }

    private static func outcomeNoun(_ outcome: ExecutionOutcome) -> String {
        switch outcome {
        case .started: return "started"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    private static func interruptReasonText(_ reason: ExecutionInterruptReason) -> String {
        switch reason {
        case .user: return "Interrupted by user."
        case .shutdown: return "Interrupted by server shutdown."
        case .superseded: return "Interrupted by a newer execution."
        case .inactivity: return "Interrupted after inactivity."
        case .unknown: return "Interrupted."
        }
    }

    private static func sessionID(in data: EventJSONValue) -> SessionID? {
        guard case .object(let fields) = data,
              case .string(let raw) = fields["sessionID"],
              !raw.isEmpty else { return nil }
        return SessionID(rawValue: raw)
    }

    private static func reason(in data: EventJSONValue) -> String? {
        guard case .object(let fields) = data,
              case .string(let raw) = fields["reason"] else { return nil }
        return raw
    }

    private static func decodeSessionError(_ data: EventJSONValue) -> SessionError.Error? {
        guard case .object(let fields) = data, let value = fields["error"] else { return nil }
        guard let encoded = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(SessionError.Error.self, from: encoded)
    }

    private static func parseLiveness(data: EventJSONValue, session: SessionID) -> ExecutionLiveness? {
        guard sessionID(in: data) == session,
              case .object(let top) = data,
              let statusValue = top["status"],
              case .object(let status) = statusValue,
              case .string(let type) = status["type"] else { return nil }
        switch type {
        case "idle":
            return .idle
        case "busy":
            return .busy
        case "retry":
            guard case .number(let attemptRaw) = status["attempt"],
                  let attempt = nonnegativeInt(attemptRaw),
                  case .string(let message) = status["message"],
                  case .number(let nextRaw) = status["next"],
                  let next = nonnegativeInt(nextRaw) else { return nil }
            // The pinned optional `action` is a structured object, not a string.
            // R09 does not model it, so it is tolerated (ignored) rather than
            // rejecting an otherwise valid retry.
            return .retry(ExecutionRetryDetail(attempt: attempt, message: message, next: next))
        default:
            return nil
        }
    }

    private static func nonnegativeInt(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
        let int = Int(value)
        guard Double(int) == value else { return nil }
        return int
    }
}
