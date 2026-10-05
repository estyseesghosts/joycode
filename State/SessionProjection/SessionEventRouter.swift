import Foundation

/// How one public event affects a session's history snapshot.
///
/// Classification is verified against pinned OpenCode v2.0.20
/// (`packages/schema/src/session-event.ts`, `core/src/session/projector.ts`,
/// `core/src/session/message-updater.ts`); see
/// `docs/plan/r08-live-reconciliation-2026-10-05.md`. Routing uses only the
/// event's own `data.sessionID`; the envelope `location`, `durable.seq` and
/// ids are never used to order events against snapshots.
enum SessionEventRoute: Equatable, Sendable {
    /// Not a session history event, or a session event verified to leave
    /// history unchanged (status, usage, viewed, rename, inbox bookkeeping,
    /// ephemeral deltas and progress, execution start).
    case ignored
    /// History for this session may have changed; an authoritative snapshot
    /// is required. Includes unknown `session.*` families with a session id.
    case historyChanged(SessionID)
    /// `session.revert.committed`: the projector deletes the boundary message
    /// and every later one. `boundary` is `data.to` when present.
    case messagesRemoved(SessionID, boundary: String?)
    /// `session.deleted`: the session and its history are gone.
    case sessionDeleted(SessionID)
    /// A session-family event whose session cannot be identified. The active
    /// session must refresh rather than guess.
    case unroutable
}

enum SessionEventRouter {
    /// Durable events the projector turns into history rows or updates
    /// (message-updater cases plus inbox delivery and fork copy), and the
    /// revert markers. Staged/cleared do not delete history but change what
    /// a transcript should present, so they conservatively invalidate.
    static let knownHistoryAffectingTypes: Set<String> = [
        "session.agent.selected", "session.model.selected", "session.moved",
        "session.inbox.delivered", "session.forked",
        "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted",
        "session.instructions.updated", "session.synthetic", "session.skill.activated",
        "session.shell.started", "session.shell.ended",
        "session.step.started", "session.step.streamed", "session.step.ended", "session.step.failed",
        "session.text.started", "session.text.ended",
        "session.reasoning.started", "session.reasoning.ended",
        "session.tool.input.started", "session.tool.input.ended",
        "session.tool.called", "session.tool.success", "session.tool.failed",
        "session.retry.scheduled",
        "session.compaction.started", "session.compaction.ended", "session.compaction.failed",
        "session.revert.staged", "session.revert.cleared",
        // Replay-only and absent from the public manifest; if one ever
        // arrives it replaces assistant content, so it is history-changing.
        "session.message.content.updated",
    ]

    /// Verified not to change history rows. Ephemeral deltas/progress are
    /// deliberately not applied in R08: text/reasoning ordinals are not
    /// persisted identifiers and cannot be assumed to equal history indices;
    /// the next durable boundary event triggers an authoritative snapshot.
    static let knownNoHistoryEffectTypes: Set<String> = [
        "session.created", "session.renamed", "session.metadata.updated", "session.permissions",
        "session.viewed", "session.usage.updated", "session.usage.recorded",
        "session.inbox.enqueued", "session.inbox.cancelled", "session.inbox.delivery.changed",
        "session.execution.started",
        "session.status", "session.idle",
        "session.text.delta", "session.reasoning.delta", "session.tool.input.delta",
        "session.tool.progress", "session.compaction.delta",
    ]

    static func route(_ envelope: EventEnvelope) -> SessionEventRoute {
        let type = envelope.type
        guard type.hasPrefix("session.") else { return .ignored }
        if knownNoHistoryEffectTypes.contains(type) { return .ignored }

        guard let sessionID = sessionID(in: envelope.data) else { return .unroutable }

        switch type {
        case "session.deleted":
            return .sessionDeleted(sessionID)
        case "session.revert.committed":
            let boundary = envelope.data.objectValue?["to"]?.stringValue
            return .messagesRemoved(sessionID, boundary: (boundary?.isEmpty == false) ? boundary : nil)
        default:
            // Known history-affecting families and unknown `session.*`
            // families alike: refresh, do not guess.
            return .historyChanged(sessionID)
        }
    }

    private static func sessionID(in data: EventJSONValue) -> SessionID? {
        guard let raw = data.objectValue?["sessionID"]?.stringValue, !raw.isEmpty else { return nil }
        return SessionID(rawValue: raw)
    }
}

private extension EventJSONValue {
    var objectValue: [String: EventJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
