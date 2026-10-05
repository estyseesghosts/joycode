import Foundation
import Combine

/// Frozen routing/readiness snapshot for one composer send.
///
/// Produced by an injected `ComposerContextProvider` closure so the store never
/// reaches into session, selection, or connection state directly. Production
/// wiring (owned by the primary, not this slice) derives it from the loaded
/// active session (identity + authoritative directory), the current service
/// connection generation, and the confirmed-current R05 agent/model readiness
/// (`SelectionStore.isSelectionCurrent` plus present agent/model values).
/// A nil `sessionID`, nil `directory`, nil `connectionGeneration`, or false
/// `isReady` each independently disable sending with a truthful reason.
struct ComposerContext: Equatable, Sendable {
    let sessionID: SessionID?
    let directory: URL?
    let connectionGeneration: UInt64?
    /// True only when the active session's agent and model selections are both
    /// confirmed current on this connection (never a retained-but-stale value).
    let isReady: Bool

    init(sessionID: SessionID?, directory: URL?, connectionGeneration: UInt64?, isReady: Bool) {
        self.sessionID = sessionID
        self.directory = directory
        self.connectionGeneration = connectionGeneration
        self.isReady = isReady
    }
}

/// Visible submission state for the currently selected session.
///
/// Only a validated `200` inbox admission is success (handled by `PromptAPI`
/// before the result reaches this store). Declared 400/401/404/409 rejections
/// are `.rejected`; every other status, transport failure, malformed or
/// mismatched success, lost reply, post-dispatch cancellation, or connection
/// replacement is conservatively `.unknown`. `.unknown` blocks resubmission
/// until a separate R12 check/manual disposition exists; it is never cleared
/// by a fake negative proof and never auto-retried.
enum ComposerSendState: Equatable, Sendable {
    case idle
    case sending(request: PromptRequest, context: ComposerContext)
    case rejected(request: PromptRequest, context: ComposerContext, problem: PromptAPIError)
    case unknown(request: PromptRequest, context: ComposerContext, problem: PromptAPIError)
}

/// Reads the current composer routing/readiness snapshot. Called only on the
/// main actor; production subscribes it to session + selection + connection.
typealias ComposerContextProvider = @MainActor () -> ComposerContext

/// Dispatches one frozen prompt admission. Production wires this to
/// `PromptAPI.send(connection:request:)`; only `CancellationError` escapes as
/// a throw, and the store converts it to `.unknown` without resending.
typealias ComposerSendAction = @MainActor @Sendable (PromptRequest) async throws -> PromptSendResult

/// Owns the multiline prompt draft per session identity plus one submission
/// attempt per session.
///
/// Boundaries: presentation (`Features/Composer`) observes `draftText`,
/// `submission`, `canSend`, and `statusMessage` only. OpenCode remains
/// authoritative: the store keeps no local transcript and fabricates no
/// optimistic message. Backend admission, permission policy, and persistence
/// are not recreated here.
///
/// Semantics:
/// - Drafts are keyed by session identity. The visible editor shows only the
///   current session's draft; switching sessions never leaks text across them.
/// - `send()` freezes the visible text, a fresh `msg_` identity, and the
///   current context. Repeat invocations while sending are suppressed.
/// - Edits made while a send is in flight are preserved: a validated admission
///   on the same connection clears the draft only when it is still exactly
///   the frozen text.
/// - A validated admission for a non-visible session clears only that
///   session's draft; results are never adopted into another session's draft.
/// - Declared rejections retain the text; explicit `retry()` issues a new
///   identity. Unknown outcomes retain text and context and block resubmission.
/// - A replaced connection generation (including disconnect) before or during
///   dispatch converts the attempt to `.unknown`; nothing is auto-resent on
///   remount, context refresh, or reconnect.
/// - Behavior never depends on view lifetime; production owns the `bind`
///   subscription and calls `refreshContext()` on session/selection/connection
///   changes.
@MainActor final class ComposerStore: ObservableObject {
    @Published private(set) var draftText: String = ""
    @Published private(set) var submission: ComposerSendState = .idle
    @Published private(set) var context: ComposerContext

    private var drafts: [SessionID: String] = [:]
    private var submissions: [SessionID: ComposerSendState] = [:]
    private var sessionKey: SessionID?
    private let readContext: ComposerContextProvider
    private let sendAction: ComposerSendAction
    private var sendTasks: [SessionID: Task<Void, Never>] = [:]
    private var sendGenerations: [SessionID: UInt64] = [:]
    private var bindings = Set<AnyCancellable>()

    init(context: @escaping ComposerContextProvider, send: @escaping ComposerSendAction) {
        self.readContext = context
        self.sendAction = send
        let initial = context()
        self.context = initial
        self.sessionKey = initial.sessionID
    }

    /// True while a prompt admission for the visible session is in flight.
    var isSending: Bool {
        if case .sending = submission { return true }
        return false
    }

    /// True when the Retry control should be offered (declared rejection only;
    /// unknown outcomes stay blocked until an R12 check/disposition exists).
    var showsRetry: Bool {
        if case .rejected = submission { return true }
        return false
    }

    /// Sending requires a connected, loaded session directory, confirmed
    /// current agent/model readiness, non-whitespace text, and no unresolved
    /// same-session submission (sending or unknown both block).
    var canSend: Bool {
        guard context.sessionID != nil else { return false }
        guard context.directory != nil else { return false }
        guard context.connectionGeneration != nil else { return false }
        guard context.isReady else { return false }
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch submission {
        case .idle, .rejected:
            return true
        case .sending, .unknown:
            return false
        }
    }

    /// Single status line for the composer: in-flight, rejected, and unknown
    /// outcomes plus truthful unavailability reasons. Nil when ready (or when
    /// the empty-draft hint is suppressed by an active submission state).
    var statusMessage: String? {
        switch submission {
        case .sending:
            return "Sending…"
        case .rejected(_, _, let problem):
            return "Not sent (\(Self.problemLabel(problem))). Edit if needed, then retry."
        case .unknown:
            return "Outcome unknown. It may still have been sent; a later check will resolve it. Do not resend yet."
        case .idle:
            break
        }
        if context.sessionID == nil { return "No active session." }
        if context.directory == nil { return "No project directory." }
        if context.connectionGeneration == nil { return "Not connected." }
        if !context.isReady { return "Select an agent and model to send." }
        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type a message to send." }
        return nil
    }

    /// Updates the visible draft and its per-session entry. Never touches any
    /// in-flight frozen request: edits during a send are preserved and only
    /// prevent the unchanged-draft clear on admission.
    func editText(_ text: String) {
        draftText = text
        if let key = sessionKey {
            drafts[key] = text
        }
    }

    /// Re-reads the injected context: persists the visible draft under its
    /// session, converts any `.sending` attempt whose frozen connection no
    /// longer matches to `.unknown` (never resending), then publishes the
    /// newly visible draft and submission. Session switches only change which
    /// per-session entries are visible; they never cancel, confirm, or move
    /// another session's attempt.
    func refreshContext() {
        let next = readContext()
        if let key = sessionKey {
            drafts[key] = draftText
        }
        let nextGeneration = next.connectionGeneration
        let staleKeys = submissions.keys.filter { key in
            if case .sending(_, let frozen) = submissions[key] {
                return frozen.connectionGeneration != nextGeneration
            }
            return false
        }
        for key in staleKeys {
            if case .sending(let request, let frozen) = submissions[key] {
                submissions[key] = .unknown(request: request, context: frozen, problem: .notConnected)
                sendGenerations[key, default: 0] &+= 1
            }
        }
        context = next
        sessionKey = next.sessionID
        if let key = sessionKey {
            draftText = drafts[key] ?? ""
            submission = submissions[key] ?? .idle
        } else {
            draftText = ""
            submission = .idle
        }
    }

    /// Freezes the visible text, a fresh `msg_` identity, and the current
    /// context, then dispatches exactly once. No-op unless `canSend` holds,
    /// so repeat clicks while sending and resubmission while unknown are
    /// suppressed without fabricating anything.
    func send() {
        // Synchronously refresh first: `bind` refreshes on a queued hop, so
        // the published context (and `canSend`) may still reflect old
        // readiness when send is tapped. Refreshing here prevents dispatching
        // a stale-readiness intent.
        refreshContext()
        guard canSend else { return }
        guard let key = sessionKey, let sessionID = context.sessionID else { return }
        let frozen = context
        // Predispatch verification: never dispatch a queued old-readiness
        // intent. If the live context no longer matches the frozen snapshot,
        // nothing was sent, so leave the draft/state untouched (idle keeps a
        // truthful `statusMessage` from the refreshed context). Sent errors
        // remain `.unknown`; this path never fabricates `.unknown`.
        let fresh = readContext()
        guard fresh == frozen else { return }
        let request = PromptRequest(
            sessionID: sessionID,
            messageID: Self.makeMessageID(),
            text: draftText
        )
        submissions[key] = .sending(request: request, context: frozen)
        if key == sessionKey {
            submission = submissions[key] ?? .idle
        }
        let attempt = (sendGenerations[key] ?? 0) &+ 1
        sendGenerations[key] = attempt
        let action = sendAction
        // One attempt per session: starting a same-session attempt replaces
        // only that session's task. Other sessions' in-flight attempts are
        // never cancelled and resolve independently.
        sendTasks[key]?.cancel()
        sendTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.sendGenerations[key] == attempt else { return }
            let dispatchContext = self.readContext()
            guard dispatchContext == frozen else {
                self.finishSending(key: key, messageID: request.messageID,
                                   next: .rejected(request: request, context: frozen, problem: .requestFailed),
                                   attempt: attempt)
                return
            }
            // Never dispatch into a known-replaced connection: the attempt is
            // already unknown and no duplicate may be sent.
            if self.readContext().connectionGeneration != frozen.connectionGeneration {
                self.finishSending(
                    key: key,
                    messageID: request.messageID,
                    next: .unknown(request: request, context: frozen, problem: .notConnected),
                    attempt: attempt
                )
                return
            }
            do {
                let result = try await action(request)
                guard attempt == self.sendGenerations[key] else { return }
                // A reply that arrives after a connection replacement cannot
                // adopt old-context facts: it stays unknown, even on success.
                if self.readContext().connectionGeneration != frozen.connectionGeneration {
                    self.finishSending(
                        key: key,
                        messageID: request.messageID,
                        next: .unknown(request: request, context: frozen, problem: .notConnected),
                        attempt: attempt
                    )
                    return
                }
                self.applyResult(result, key: key, request: request, frozen: frozen, attempt: attempt)
            } catch is CancellationError {
                guard attempt == self.sendGenerations[key] else { return }
                // Cancellation after dispatch cannot prove rejection: retain
                // the original text/context as unknown, never retry.
                self.finishSending(
                    key: key,
                    messageID: request.messageID,
                    next: .unknown(request: request, context: frozen, problem: .requestFailed),
                    attempt: attempt
                )
            } catch {
                guard attempt == self.sendGenerations[key] else { return }
                self.finishSending(
                    key: key,
                    messageID: request.messageID,
                    next: .unknown(request: request, context: frozen, problem: .requestFailed),
                    attempt: attempt
                )
            }
        }
    }

    /// Explicit retry after a declared rejection: clears the rejected marker
    /// and dispatches anew with a fresh identity. Returns false (no dispatch)
    /// for idle, sending, and unknown states; unknown stays blocked until a
    /// separate R12 check/manual disposition exists.
    @discardableResult
    func retry() -> Bool {
        guard case .rejected = submission else { return false }
        if let key = sessionKey {
            submissions[key] = .idle
            submission = .idle
        }
        send()
        return isSending
    }

    /// Composition-owned subscription so correctness never depends on view
    /// lifetime. Any session, selection, or connection publication only
    /// refreshes the visible context; in-flight attempts are never cancelled
    /// or resent by a view appearing or disappearing.
    func bind(sessionStore: ActiveSessionStore, selectionStore: SelectionStore, connectionOwner: ServiceConnectionOwner) {
        bindings.removeAll()
        sessionStore.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshContext() }
            }
            .store(in: &bindings)
        selectionStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshContext() }
            }
            .store(in: &bindings)
        connectionOwner.$currentContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshContext() }
            }
            .store(in: &bindings)
    }

    // MARK: - Internals

    private func applyResult(_ result: PromptSendResult, key: SessionID, request: PromptRequest, frozen: ComposerContext, attempt: UInt64) {
        switch result {
        case .admitted(let message):
            // Defense in depth alongside PromptAPI validation: only the exact
            // frozen identity/session/text counts as admission. Anything else
            // stays ambiguous with the original draft/context retained.
            guard message.id == request.messageID,
                  message.sessionID == request.sessionID.rawValue,
                  message.type == "user",
                  message.text == request.text
            else {
                finishSending(
                    key: key,
                    messageID: request.messageID,
                    next: .unknown(request: request, context: frozen, problem: .requestFailed),
                    attempt: attempt
                )
                return
            }
            // Validated admission on the same connection: clear only the
            // original unchanged draft. Edits made during the send are
            // preserved; another session's draft is never touched. Clearing
            // happens only while this attempt is still `.sending`, so a
            // connection replacement that already converted it to `.unknown`
            // retains the original text.
            guard attempt == sendGenerations[key] else { return }
            if case .sending(let currentRequest, _) = submissions[key],
               currentRequest.messageID == request.messageID {
                let current = (key == sessionKey) ? draftText : (drafts[key] ?? "")
                if current == request.text {
                    drafts[key] = ""
                    if key == sessionKey {
                        draftText = ""
                    }
                }
                submissions[key] = .idle
                if key == sessionKey {
                    submission = .idle
                }
            }
        case .rejected(let problem):
            finishSending(
                key: key,
                messageID: request.messageID,
                next: .rejected(request: request, context: frozen, problem: problem),
                attempt: attempt
            )
        case .unknown(let problem):
            finishSending(
                key: key,
                messageID: request.messageID,
                next: .unknown(request: request, context: frozen, problem: problem),
                attempt: attempt
            )
        }
    }

    private func finishSending(key: SessionID, messageID: String, next: ComposerSendState, attempt: UInt64) {
        guard sendGenerations[key] == attempt else { return }
        guard case .sending(let current, _) = submissions[key],
              current.messageID == messageID else { return }
        submissions[key] = next
        if key == sessionKey {
            submission = next
        }
    }

    private static func makeMessageID() -> String {
        "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func problemLabel(_ problem: PromptAPIError) -> String {
        switch problem {
        case .notConnected:
            return "not connected"
        case .unauthorized:
            return "not authorized"
        case .notFound:
            return "session not found"
        case .conflict:
            return "conflict"
        case .backend(let code):
            return "server error \(code)"
        case .malformedResponse:
            return "malformed response"
        case .requestFailed:
            return "request failed"
        }
    }
}
