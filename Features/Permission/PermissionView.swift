import SwiftUI

/// Pending session permission approvals (R10): authoritative pending list with
/// explicit allow-once / reject replies.
///
/// Presentation only. The application composition owns all context and event
/// bindings (see `ConversationComposition.permission`); this view creates no
/// observation tasks and issues no automatic reads. Only the P1-supported
/// `once`/`reject` choices are offered: permanent auto-approval (`always`)
/// needs a separate policy disposition and is never exposed here.
///
/// Honesty rules mirrored from the store:
/// - Buttons disable while a reply is uncertain (in flight, accepted awaiting
///   its confirming read, or lost-reply ambiguity), while the list is loading
///   or stale, and whenever the id is absent from the authoritative list.
/// - Rejected replies and honest missing requests (`lastError`), lost-reply
///   ambiguity (`attentionReason`), and staleness stay visible even when the
///   list is empty: absence is never presented as success.
struct PermissionView: View {
    @ObservedObject var store: PermissionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("permission-title")
            if store.pending.isEmpty {
                Text(emptyLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("permission-empty")
            } else {
                ForEach(store.pending, id: \.id) { request in
                    PermissionRequestRow(store: store, request: request)
                }
            }
            if let notice = noticeText {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("permission-status")
            }
            HStack(spacing: 8) {
                Button("Refresh permissions") { store.refresh() }
                    .disabled(store.isLoading)
                    .accessibilityIdentifier("permission-refresh")
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading permissions")
                }
                if store.isStale {
                    Text("Stale")
                        .font(.caption)
                        .accessibilityIdentifier("permission-stale")
                }
            }
        }
        .accessibilityIdentifier("permission-view")
    }

    private var emptyLabel: String {
        if store.isLoading { return "Loading permissions…" }
        if store.isStale { return "Pending permissions unknown. Last read may be out of date." }
        if store.provenance == nil { return "Permission state unavailable." }
        return "No pending permissions."
    }

    /// Lost-reply ambiguity outranks a transient reply notice; both survive
    /// the confirming reread, so they render even after the list empties.
    private var noticeText: String? {
        if let reason = store.attentionReason { return reason }
        return store.lastError
    }
}

private struct PermissionRequestRow: View {
    @ObservedObject var store: PermissionStore
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Action: \(request.action)")
                .font(.callout)
                .accessibilityIdentifier("permission-action")
            Text("Resources: \(request.resources.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("permission-resources")
            Text("Session: \(request.sessionID)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("permission-session")
            Text("Request: \(request.id)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("permission-request-id")
            if let message = request.message, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .accessibilityIdentifier("permission-message")
            }
            HStack(spacing: 8) {
                Button("Allow once") { store.reply(requestID: request.id, decision: .once) }
                    .disabled(!canReply)
                    .accessibilityIdentifier("permission-allow-once")
                Button("Reject") { store.reply(requestID: request.id, decision: .reject) }
                    .disabled(!canReply)
                    .accessibilityIdentifier("permission-reject")
                if store.isReplying(request.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sending permission reply")
                }
                if store.hasUnknownReply(request.id) {
                    Text("Reply unconfirmed. Refresh to reconcile; it is not retried automatically.")
                        .font(.caption)
                        .accessibilityIdentifier("permission-unknown")
                }
            }
        }
        .accessibilityIdentifier("permission-row")
    }

    /// Approval needs the id in the authoritative list with no uncertain reply
    /// state (`canReply`), plus a current list: a load in flight or a stale
    /// list must not approve. Silence is never approval.
    private var canReply: Bool {
        !store.isLoading && !store.isStale && store.canReply(request.id)
    }
}
