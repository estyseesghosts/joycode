import Foundation
import Combine

/// Ephemeral streaming overlay and stable presentation identity (H07).
///
/// The overlay holds live-only streaming state (text/reasoning deltas, tool
/// input/progress) that must never corrupt the persisted transcript model and
/// must never trigger history GETs. It is owned (in H08) alongside the
/// durable projection, but it never touches `TranscriptMessage` itself:
/// terminal stream events report their authoritative text via
/// `TranscriptLiveOverlayOutcome.settled` so the caller can settle it where
/// the ordinal-to-content mapping is known, and unobserved terminals request
/// a targeted message refresh instead of fabricating content.
///
/// Contract facts (verified, OpenCode v2.0.20): `text`/`reasoning`
/// started/delta/ended carry `assistantMessageID` and `ordinal`
/// (non-negative int; NOT a persisted content index). started/ended are
/// durable signals, delta is ephemeral. `text.ended`/`reasoning.ended` carry
/// the full terminal `text`. `tool.input.delta` and `tool.progress` are
/// ephemeral; tool success/failed are self-contained terminals.
///
/// No I/O, no clock, no SwiftUI. The overlay takes no loader and performs no
/// transport by construction: `apply` is a synchronous pure-ish mutation over
/// the typed events H06's decoder already produces.

// MARK: - Live-only identity

/// Live-only content identity. Deliberately distinct from
/// `TranscriptContentID`: there is no conversion to or from it, it is never
/// `Codable`, and it is never persisted. Text/reasoning slots are keyed by
/// `(assistantMessageID, kind, ordinal)`; tool overlays by
/// `(assistantMessageID, toolID)`. The ordinal is a live stream slot, never a
/// persisted content index.
enum LiveContentID: Hashable, Sendable {
    case text(assistantMessageID: String, ordinal: Int)
    case reasoning(assistantMessageID: String, ordinal: Int)
    case tool(assistantMessageID: String, toolID: String)

    var assistantMessageID: String {
        switch self {
        case .text(let messageID, _): return messageID
        case .reasoning(let messageID, _): return messageID
        case .tool(let messageID, _): return messageID
        }
    }
}

// MARK: - Overlay outcome

/// What applying one typed event did. H08 reacts to these without re-reading
/// history: `.updated` needs only a coalesced presentation flush, `.settled`
/// and `.needsMessageRefresh` (both from terminal events) flush immediately.
enum TranscriptLiveOverlayOutcome: Equatable, Sendable {
    /// Ephemeral state changed; a coalesced flush is sufficient.
    case updated
    /// A terminal event removed a live slot; flush immediately. For streams
    /// the full terminal text is authoritative (it may differ from the
    /// accumulated deltas); for tools the terminal event is self-contained.
    case settled(TranscriptLiveSettlement)
    /// A terminal stream event arrived for a slot never observed. The caller
    /// must reconcile that assistant message; the overlay fabricated nothing.
    case needsMessageRefresh(messageID: String)
    /// Nothing changed: wrong session, duplicate start, delta/progress
    /// without a slot (dropped, never fabricated), duplicate or late
    /// terminal already settled, or a non-overlay event.
    case ignored
}

/// Terminal payload removed from the overlay.
enum TranscriptLiveSettlement: Equatable, Sendable {
    /// Stream slot removed; `text` is the authoritative terminal text.
    case stream(id: LiveContentID, text: String)
    /// Tool overlay removed; the terminal event carries everything durable.
    case tool(id: LiveContentID)
}

// MARK: - Live snapshot item

/// One live overlay entry for presentation. `text` is accumulated ephemeral
/// text (stream deltas) or partial tool input; `toolName`/`toolMetadata` are
/// set only for `.tool` ids.
struct TranscriptLiveItem: Equatable, Sendable {
    let id: LiveContentID
    let text: String
    let toolName: String?
    let toolMetadata: TranscriptJSONValue?

    static func stream(id: LiveContentID, text: String) -> TranscriptLiveItem {
        TranscriptLiveItem(id: id, text: text, toolName: nil, toolMetadata: nil)
    }

    static func tool(id: LiveContentID, name: String, input: String, metadata: TranscriptJSONValue?) -> TranscriptLiveItem {
        TranscriptLiveItem(id: id, text: input, toolName: name, toolMetadata: metadata)
    }
}

// MARK: - Overlay

/// Value-model ephemeral overlay. The store will own one of these (H08);
/// until then it is driven directly in tests and by `TranscriptLivePublisher`.
struct TranscriptLiveOverlay: Sendable {
    /// Bound on remembered terminal ids used to tell late duplicates
    /// (`.ignored`) from never-observed terminals (`.needsMessageRefresh`).
    /// Oldest entries drop first; evicted duplicates degrade to a harmless
    /// targeted refresh, never to fabricated content.
    static let maximumRecentlySettled = 256

    private struct ToolSlot: Equatable, Sendable {
        var name: String
        var input: String
        var metadata: TranscriptJSONValue?
    }

    /// Accumulated stream text by live slot, in start order.
    private var streams: [LiveContentID: String] = [:]
    /// Live tool overlays by live id.
    private var tools: [LiveContentID: ToolSlot] = [:]
    /// Start order across streams and tools for stable snapshots.
    private var startOrder: [LiveContentID] = []
    /// Bounded FIFO of settled live ids for duplicate/late-terminal detection.
    private var recentlySettled: [LiveContentID] = []

    var isEmpty: Bool { streams.isEmpty && tools.isEmpty }

    /// Ordered snapshot (global start order) for presentation.
    var items: [TranscriptLiveItem] {
        startOrder.compactMap { id in
            if let text = streams[id] { return .stream(id: id, text: text) }
            if let slot = tools[id] {
                return .tool(id: id, name: slot.name, input: slot.input, metadata: slot.metadata)
            }
            return nil
        }
    }

    /// Ordered live items for one assistant message, in start order.
    func items(for assistantMessageID: String) -> [TranscriptLiveItem] {
        items.filter { $0.id.assistantMessageID == assistantMessageID }
    }

    /// Applies one typed event for the active session. Events for any other
    /// session are ignored and never mutate.
    mutating func apply(_ event: SessionTranscriptEvent, activeSession: SessionID) -> TranscriptLiveOverlayOutcome {
        guard event.sessionID == activeSession else { return .ignored }
        switch event {
        case .textStarted(_, let messageID, let ordinal, _):
            return startStream(.text(assistantMessageID: messageID, ordinal: ordinal))
        case .textDelta(_, let messageID, let ordinal, let delta, _):
            return appendStream(.text(assistantMessageID: messageID, ordinal: ordinal), delta: delta)
        case .textEnded(_, let messageID, let ordinal, let text, _):
            return endStream(.text(assistantMessageID: messageID, ordinal: ordinal), messageID: messageID, terminalText: text)
        case .reasoningStarted(_, let messageID, let ordinal, _):
            return startStream(.reasoning(assistantMessageID: messageID, ordinal: ordinal))
        case .reasoningDelta(_, let messageID, let ordinal, let delta, _):
            return appendStream(.reasoning(assistantMessageID: messageID, ordinal: ordinal), delta: delta)
        case .reasoningEnded(_, let messageID, let ordinal, let text, _):
            return endStream(.reasoning(assistantMessageID: messageID, ordinal: ordinal), messageID: messageID, terminalText: text)
        case .toolInputStarted(_, let messageID, let toolID, let name, _):
            return startTool(.tool(assistantMessageID: messageID, toolID: toolID), name: name)
        case .toolInputDelta(_, let messageID, let toolID, let delta, _):
            return appendToolInput(.tool(assistantMessageID: messageID, toolID: toolID), delta: delta)
        case .toolProgress(_, let messageID, let toolID, let metadata, _):
            return updateToolMetadata(.tool(assistantMessageID: messageID, toolID: toolID), metadata: metadata)
        case .toolInputEnded(_, let messageID, let toolID, _, _),
            .toolCalled(_, let messageID, let toolID, _, _),
            .toolSuccess(_, let messageID, let toolID, _, _, _, _),
            .toolFailed(_, let messageID, let toolID, _, _, _, _, _):
            return settleTool(.tool(assistantMessageID: messageID, toolID: toolID))
        case .stepEnded(_, let messageID, _, _),
            .stepFailed(_, let messageID, _, _, _):
            return clearAssistant(messageID) ? .updated : .ignored
        case .stepStarted, .stepStreamed:
            return .ignored
        }
    }

    /// Drops every overlay slot for one assistant message (step terminal).
    /// Late stream terminals for cleared slots were never observed, so they
    /// still request reconciliation rather than being mistaken for settled
    /// duplicates; cleared ids are deliberately NOT added to
    /// `recentlySettled` because no terminal text was observed for them.
    /// Returns true when anything was removed.
    @discardableResult
    mutating func clear(assistantMessageID: String) -> Bool {
        clearAssistant(assistantMessageID)
    }

    /// Drops all overlay state, including duplicate memory (context change).
    mutating func reset() {
        streams = [:]
        tools = [:]
        startOrder = []
        recentlySettled = []
    }

    // MARK: - Streams

    private mutating func startStream(_ id: LiveContentID) -> TranscriptLiveOverlayOutcome {
        // Duplicate start is a no-op: never reset accumulated text.
        guard streams[id] == nil else { return .ignored }
        streams[id] = ""
        startOrder.append(id)
        recentlySettled.removeAll { $0 == id }
        return .updated
    }

    private mutating func appendStream(_ id: LiveContentID, delta: String) -> TranscriptLiveOverlayOutcome {
        // A missed start must never fabricate a slot or guess an index.
        guard streams[id] != nil else { return .ignored }
        streams[id, default: ""].append(delta)
        return .updated
    }

    private mutating func endStream(_ id: LiveContentID, messageID: String, terminalText: String) -> TranscriptLiveOverlayOutcome {
        guard streams[id] != nil else {
            // A late duplicate of an already-settled slot is harmless;
            // anything else needs reconciliation of that message.
            return recentlySettled.contains(id) ? .ignored : .needsMessageRefresh(messageID: messageID)
        }
        streams.removeValue(forKey: id)
        startOrder.removeAll { $0 == id }
        rememberSettled(id)
        return .settled(.stream(id: id, text: terminalText))
    }

    // MARK: - Tools

    private mutating func startTool(_ id: LiveContentID, name: String) -> TranscriptLiveOverlayOutcome {
        // Duplicate start is a no-op: never reset accumulated input.
        guard tools[id] == nil else { return .ignored }
        tools[id] = ToolSlot(name: name, input: "", metadata: nil)
        startOrder.append(id)
        recentlySettled.removeAll { $0 == id }
        return .updated
    }

    private mutating func appendToolInput(_ id: LiveContentID, delta: String) -> TranscriptLiveOverlayOutcome {
        guard tools[id] != nil else { return .ignored }
        tools[id]?.input.append(delta)
        return .updated
    }

    private mutating func updateToolMetadata(_ id: LiveContentID, metadata: TranscriptJSONValue) -> TranscriptLiveOverlayOutcome {
        guard tools[id] != nil else { return .ignored }
        tools[id]?.metadata = metadata
        return .updated
    }

    /// Tool terminal events are self-contained, so the overlay only clears.
    /// H08 applies durability from the event itself (H06 reducer). A terminal
    /// for a slot never owned changes nothing here (`.ignored`); the durable
    /// reducer remains authoritative for refresh decisions on tools, where
    /// the stable toolID needs no overlay-observed mapping. Duplicates and
    /// late arrivals are equally harmless.
    private mutating func settleTool(_ id: LiveContentID) -> TranscriptLiveOverlayOutcome {
        guard tools[id] != nil else { return .ignored }
        tools.removeValue(forKey: id)
        startOrder.removeAll { $0 == id }
        rememberSettled(id)
        return .settled(.tool(id: id))
    }

    // MARK: - Clearing

    private mutating func clearAssistant(_ messageID: String) -> Bool {
        let streamIDs = streams.keys.filter { $0.assistantMessageID == messageID }
        let toolIDs = tools.keys.filter { $0.assistantMessageID == messageID }
        guard !streamIDs.isEmpty || !toolIDs.isEmpty else { return false }
        for id in streamIDs { streams.removeValue(forKey: id) }
        for id in toolIDs { tools.removeValue(forKey: id) }
        startOrder.removeAll { $0.assistantMessageID == messageID }
        return true
    }

    private mutating func rememberSettled(_ id: LiveContentID) {
        recentlySettled.removeAll { $0 == id }
        recentlySettled.append(id)
        while recentlySettled.count > Self.maximumRecentlySettled {
            recentlySettled.removeFirst()
        }
    }
}

// MARK: - Publication coalescing

/// One-shot flush task. Cancel drops the pending action; `run` performs it
/// exactly once. Owned by the publisher and the scheduler; tests drive it
/// through `ManualFlushScheduler` with no wall-clock sleeps.
@MainActor final class TranscriptLiveFlushTask {
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    var isCancelled: Bool { action == nil }

    func cancel() {
        action = nil
    }

    func run() {
        let next = action
        action = nil
        next?()
    }
}

/// Schedules at most one pending presentation flush. Production uses
/// `TaskFlushScheduler`; tests inject `ManualFlushScheduler` (defined in the
/// test target so no test double ships in the app).
protocol TranscriptLiveFlushScheduler: Sendable {
    @MainActor func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TranscriptLiveFlushTask
}

/// Wall-clock scheduler for production (H08 wiring). One-shot only: no
/// repeating or idle timer.
struct TaskFlushScheduler: TranscriptLiveFlushScheduler {
    @MainActor func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> TranscriptLiveFlushTask {
        let task = TranscriptLiveFlushTask(action: action)
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            task.run()
        }
        return task
    }
}

/// Owns the overlay and publishes coalesced snapshots for presentation (H08
/// will own an instance alongside the store; this class never touches the
/// store itself).
///
/// - Every event mutates the overlay immediately.
/// - `.updated` (ephemeral) requests a flush, but at most one flush task is
///   ever pending per display interval no matter how many events arrive.
/// - `.settled` / `.needsMessageRefresh` (terminal events) flush immediately
///   and cancel any pending coalesced task.
/// - When nothing is dirty nothing is scheduled: no repeating or idle timer.
/// - `liveItems` changes only on flush.
/// - Every outcome is also forwarded to `onOutcome` so H08 can react to
///   `.settled` (settle into the durable projection) and
///   `.needsMessageRefresh` (targeted message read).
@MainActor final class TranscriptLivePublisher: ObservableObject {
    /// Latest flushed snapshot, in global start order. Updated only on flush.
    @Published private(set) var liveItems: [TranscriptLiveItem] = []

    /// Outcome of every applied event, in order. H08 sets this to settle
    /// terminals and reconcile unobserved slots.
    var onOutcome: ((TranscriptLiveOverlayOutcome) -> Void)?

    private(set) var activeSession: SessionID

    private var overlay = TranscriptLiveOverlay()
    private let scheduler: TranscriptLiveFlushScheduler
    private let flushInterval: Duration
    private var pendingTask: TranscriptLiveFlushTask?

    /// True while a coalesced flush is scheduled but not yet run.
    var hasPendingFlush: Bool { pendingTask?.isCancelled == false }

    init(
        activeSession: SessionID,
        flushInterval: Duration = .milliseconds(50),
        scheduler: TranscriptLiveFlushScheduler = TaskFlushScheduler(),
        onOutcome: ((TranscriptLiveOverlayOutcome) -> Void)? = nil
    ) {
        self.activeSession = activeSession
        self.flushInterval = flushInterval
        self.scheduler = scheduler
        self.onOutcome = onOutcome
    }

    /// Applies one typed event: overlay mutates immediately, publication is
    /// coalesced (ephemeral) or immediate (terminal).
    func receive(_ event: SessionTranscriptEvent) {
        let outcome = overlay.apply(event, activeSession: activeSession)
        onOutcome?(outcome)
        switch outcome {
        case .updated:
            requestCoalescedFlush()
        case .settled, .needsMessageRefresh:
            flushImmediately()
        case .ignored:
            break
        }
    }

    /// Drops all overlay and published state (context change). H08 calls this
    /// when the active session changes.
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        overlay.reset()
        if !liveItems.isEmpty { liveItems = [] }
    }

    /// Immediate flush (also used by tests to drive manual-scheduler runs).
    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        let next = overlay.items
        if next != liveItems { liveItems = next }
    }

    private func requestCoalescedFlush() {
        guard !hasPendingFlush else { return }
        pendingTask = scheduler.schedule(after: flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flushImmediately() {
        flush()
    }
}

// MARK: - Stable presentation identity

/// Stable presentation identity for transcript rows and content.
///
/// - `.message`: history messages by their history record id.
/// - `.tool`: persisted tools by `(messageID, toolID)` (stable tool id).
/// - `.snapshotContent`: persisted text/reasoning/opaque content by
///   `(messageID, snapshot-relative index)`. Explicitly NOT stable across
///   snapshots and NEVER derived from a live ordinal: ordinals are ephemeral
///   stream slots, not content indices.
/// - `.live`: overlay items by their `LiveContentID`; never equal to, and
///   never convertible to, a persisted identity.
/// - `.snapshotMessage`: messages without a history id (id-less opaque rows)
///   by snapshot-relative position; same stability caveat as
///   `.snapshotContent`.
enum TranscriptPresentationID: Hashable, Sendable {
    case message(historyID: String)
    case tool(messageID: String, toolID: String)
    case snapshotContent(messageID: String, index: Int)
    case live(LiveContentID)
    case snapshotMessage(index: Int)
}

/// One persisted content item with its stable presentation identity.
struct TranscriptPresentationContent: Equatable, Sendable {
    let id: TranscriptPresentationID
    let content: TranscriptContent
}

/// One transcript row with model-supplied identity: persisted contents with
/// stable ids plus the live overlay items for that assistant message.
struct TranscriptPresentationRow: Equatable, Sendable {
    let id: TranscriptPresentationID
    let message: TranscriptMessage
    /// Assistant content only; empty for every other message kind.
    let contents: [TranscriptPresentationContent]
    /// Live overlay items for this assistant message, in start order; empty
    /// for every other message kind and until H08 supplies overlay values.
    let liveItems: [TranscriptLiveItem]
}

/// Pure builder from the store's messages plus the overlay snapshot. The view
/// takes these rows as input instead of reconstructing identity per body
/// evaluation; until H08 has the store supply this model, the view invokes
/// this builder with the store's `messages` (and an empty live list).
enum TranscriptPresentation {
    static func items(messages: [TranscriptMessage], live: [TranscriptLiveItem] = []) -> [TranscriptPresentationRow] {
        messages.enumerated().map { index, message in
            let rowID: TranscriptPresentationID = message.messageID.map(TranscriptPresentationID.message) ?? .snapshotMessage(index: index)
            guard case .assistant(let assistant) = message else {
                return TranscriptPresentationRow(id: rowID, message: message, contents: [], liveItems: [])
            }
            let contents = assistant.content.enumerated().map { position, content in
                TranscriptPresentationContent(id: contentID(messageID: assistant.id, index: position, content: content), content: content)
            }
            let liveItems = live.filter { $0.id.assistantMessageID == assistant.id }
            return TranscriptPresentationRow(id: rowID, message: message, contents: contents, liveItems: liveItems)
        }
    }

    private static func contentID(messageID: String, index: Int, content: TranscriptContent) -> TranscriptPresentationID {
        if case .tool(let tool) = content {
            return .tool(messageID: messageID, toolID: tool.id)
        }
        // Text, reasoning, and opaque content share snapshot-relative
        // identity. Ordinals never appear here: they are live stream slots.
        return .snapshotContent(messageID: messageID, index: index)
    }
}
