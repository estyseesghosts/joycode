import SwiftUI

/// Transcript presentation for the current session: authoritative snapshots
/// kept current by the store's event-driven resynchronization (R08).
///
/// Plain SwiftUI scroll of transcript rows backed by `TranscriptStore`:
/// user/system/synthetic/skill text, assistant text, reasoning in a
/// `DisclosureGroup`, tool calls with status plus expandable typed
/// inputs/outputs/errors from the nested `state` object, structured assistant
/// errors, named fallbacks for retained variants, and visible
/// unsupported/malformed placeholders with fixed reasons.
///
/// Safety: text renders from typed cases only. File outputs render as a URI
/// label (no auto-open, no network, no load). Opaque entries render a fixed
/// label with their kind/reason; raw JSON payloads (which may embed base64
/// bytes) are never dumped. No paging or event handling lives here; the view
/// shows the store's sync state, offers an explicit Refresh, and creates no
/// observation tasks (composition binds the store's context and event seams).
struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(syncLabel)
                    .font(.caption)
                    .accessibilityIdentifier("transcript-sync")
                if store.isLoading, store.synchronization != .resyncing {
                    ProgressView()
                        .accessibilityIdentifier("transcript-loading")
                }
                if store.isStale {
                    Text("Stale")
                        .font(.caption)
                        .accessibilityIdentifier("transcript-stale")
                }
                if let error = store.lastError {
                    Text("Couldn't refresh (\(errorLabel(error))). Showing last snapshot.")
                        .font(.caption)
                        .accessibilityIdentifier("transcript-error")
                }
                Spacer()
                Button("Refresh history") { store.refresh() }
                    .disabled(store.unavailableMessage != nil)
                    .accessibilityIdentifier("transcript-refresh")
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            if store.messages.isEmpty, !store.isLoading {
                Text(store.unavailableMessage ?? "No messages yet · Most recent 50")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcript-empty")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(identifiedMessages) { row in
                            TranscriptMessageRow(message: row.message)
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("transcript-list")
            }
        }
        .accessibilityIdentifier("transcript-view")
    }

    private struct Row: Identifiable {
        let id: Identity
        let message: TranscriptMessage
    }

    private enum Identity: Hashable {
        case message(String, occurrence: Int)
        case fallback(Int)
    }

    private var identifiedMessages: [Row] {
        var occurrences: [String: Int] = [:]
        return store.messages.enumerated().map { index, message in
            guard let id = message.messageID else { return Row(id: .fallback(index), message: message) }
            let occurrence = occurrences[id, default: 0]
            occurrences[id] = occurrence + 1
            return Row(id: .message(id, occurrence: occurrence), message: message)
        }
    }

    /// Never says "Live" without positive stream evidence from the store.
    private var syncLabel: String {
        switch store.synchronization {
        case .live: return "Live · Most recent 50"
        case .resyncing: return "Updating · Most recent 50"
        case .hydrating: return "Loading · Most recent 50"
        case .awaitingStream: return "Connecting to live updates…"
        case .snapshotOnly, .refreshFailed, .unavailable: return "Snapshot · Most recent 50"
        case .streamLost: return "Live updates stopped · Snapshot may be out of date"
        case .sessionRemoved: return "Session deleted"
        }
    }

    private func errorLabel(_ error: TranscriptAPIError) -> String {
        switch error {
        case .notConnected: return "not connected"
        case .unauthorized: return "not authorized"
        case .notFound: return "session not found"
        case .backend(let code): return "server error \(code)"
        case .malformedResponse: return "malformed response"
        case .requestFailed: return "request failed"
        case .invalidQuery: return "invalid request"
        }
    }
}

private struct TranscriptMessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        switch message {
        case .user(let text):
            TranscriptTextRow(label: "You", text: text.text)
        case .system(let text):
            TranscriptTextRow(label: "System", text: text.text)
        case .synthetic(let text):
            TranscriptTextRow(label: "Synthetic", text: text.text)
        case .skill(let text):
            TranscriptTextRow(label: "Skill", text: text.text)
        case .assistant(let assistant):
            TranscriptAssistantRow(assistant: assistant)
        case .agentSwitched(let variant):
            TranscriptRetainedRow(title: "Agent changed", variant: variant)
        case .modelSwitched(let variant):
            TranscriptRetainedRow(title: "Model changed", variant: variant)
        case .locationSwitched(let variant):
            TranscriptRetainedRow(title: "Location changed", variant: variant)
        case .shell(let variant):
            TranscriptRetainedRow(title: "Shell", variant: variant)
        case .compaction(let variant):
            TranscriptRetainedRow(title: "Compaction", variant: variant)
        case .idle(let variant):
            TranscriptRetainedRow(title: "Idle", variant: variant)
        case .opaque(let opaque):
            Text("Unsupported message (\(opaque.kind ?? "unknown")).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcript-opaque-message")
        }
    }
}

private struct TranscriptTextRow: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("transcript-row")
    }
}

private struct TranscriptAssistantRow: View {
    let assistant: TranscriptAssistantMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assistant · \(assistant.agent)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let finish = assistant.finish {
                Text("Finished: \(finish)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = assistant.error {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Error: \(error.type)")
                        .font(.callout)
                    Text(error.message)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let status = error.status {
                        Text("Status \(status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("transcript-assistant-error")
            }
            ForEach(Array(assistant.content.enumerated()), id: \.offset) { _, content in
                TranscriptContentRow(content: content)
            }
        }
        .accessibilityIdentifier("transcript-row")
    }
}

private struct TranscriptContentRow: View {
    let content: TranscriptContent

    var body: some View {
        switch content {
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
        case .reasoning(let text):
            DisclosureGroup("Reasoning") {
                Text(text)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("transcript-reasoning")
        case .tool(let tool):
            TranscriptToolRow(tool: tool)
        case .opaque(let opaque):
            Text("Unsupported content (\(opaque.kind ?? "unknown"), \(opaque.reason)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcript-opaque-content")
        }
    }
}

private struct TranscriptToolRow: View {
    let tool: TranscriptToolContent

    var body: some View {
        DisclosureGroup("\(tool.name) · \(tool.state.kind)") {
            switch tool.state {
            case .streaming(let input):
                Text(input)
                    .textSelection(.enabled)
            case .running(let input, let metadata):
                TranscriptStructuredValue(
                    title: "Input",
                    value: input,
                    metadata: metadata
                )
            case .completed(let input, let content, let metadata):
                TranscriptStructuredValue(
                    title: "Input",
                    value: input,
                    metadata: metadata
                )
                TranscriptToolOutputs(outputs: content)
            case .error(let input, let error, let content, let metadata):
                TranscriptStructuredValue(
                    title: "Input",
                    value: input,
                    metadata: metadata
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Error: \(error.type)")
                        .font(.callout)
                    Text(error.message)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let status = error.status {
                        Text("Status \(status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let content {
                    TranscriptToolOutputs(outputs: content)
                }
            }
        }
        .accessibilityIdentifier("transcript-tool")
    }
}

/// Structured (never raw) summary of a tool input/metadata object: field
/// names only, never dumped JSON. Scalar leaves render truncated so payload
/// bytes cannot flood the transcript.
private struct TranscriptStructuredValue: View {
    let title: String
    let value: TranscriptJSONValue
    let metadata: TranscriptJSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(TranscriptJSONSummary.describe(value))")
                .font(.callout)
                .textSelection(.enabled)
            if let metadata {
                Text("Metadata: \(TranscriptJSONSummary.describe(metadata))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TranscriptToolOutputs: View {
    let outputs: [TranscriptToolOutput]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(outputs.enumerated()), id: \.offset) { _, output in
                switch output {
                case .text(let text):
                    Text(text)
                        .textSelection(.enabled)
                case .file(let uri, let mime, let name):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name ?? "Attached file")
                            .font(.callout)
                        // URI label only: never auto-opened, fetched, or loaded.
                        Text("\(uri.hasPrefix("data:") ? "Embedded file (not displayed)" : String(uri.prefix(512))) (\(mime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("transcript-tool-file")
                }
            }
        }
    }
}

/// Named fallback for retained variants (`agent-switched`, `model-switched`,
/// `location-switched`, `shell`, `compaction`, `idle`): a human-readable name
/// without interpreting or dumping the preserved raw value.
private struct TranscriptRetainedRow: View {
    let title: String
    let variant: TranscriptRetainedVariant

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("transcript-retained")
    }
}

private enum TranscriptJSONSummary {
    /// Field-name summary of a JSON value. Objects render as their sorted
    /// field names with a count; strings truncate; raw payloads are never
    /// interpolated verbatim beyond a short scalar preview.
    static func describe(_ value: TranscriptJSONValue, maxStringLength: Int = 200, depth: Int = 1) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            return String(number)
        case .string(let text):
            return String(text.prefix(maxStringLength)) + (text.count > maxStringLength ? "…" : "")
        case .array(let items):
            return "\(items.count) item(s)"
        case .object(let object):
            guard depth > 0 else { return "\(object.count) field(s)" }
            return object.keys.sorted().prefix(10).map { key in
                "\(key): \(describe(object[key]!, maxStringLength: maxStringLength, depth: depth - 1))"
            }.joined(separator: ", ")
        }
    }
}
