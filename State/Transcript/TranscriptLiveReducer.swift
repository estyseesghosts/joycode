/// Pure durable reducer for the assistant execution path.
///
/// Input is the current transcript projection plus one typed
/// `SessionTranscriptEvent`. Output is either an updated projection or a
/// reconciliation request. The reducer never fabricates state it was not
/// given: missing prerequisites yield targeted/full refresh requests, and
/// terminal facts never regress.
///
/// Rules of note:
/// - Events for another session never mutate.
/// - Ordinals are not content indices: `text.ended`/`reasoning.ended` cannot
///   reproduce the projector's "latest text" / "latest reasoning without
///   completed" target without the applied start events, so they request a
///   targeted message read. H07/H08 settle presentation via the overlay or a
///   targeted read; this reducer only guards the durable model.
/// - Ephemeral overlays (deltas, progress, streamed markers, `*.started`
///   slots) are H07 concerns and leave durable state untouched.
///
/// No I/O, no clock, no UI framework.
enum TranscriptLiveReduction: Equatable, Sendable {
    case applied(messages: [TranscriptMessage])
    case needsMessageRefresh(messageID: String)
    case needsFullRefresh(TranscriptLiveRefreshReason)
    case ignored
}

enum TranscriptLiveRefreshReason: Equatable, Sendable {
    case malformedEvent
}

/// Live stream slot kind for durable text/reasoning settlement (H08).
/// Mirrors the projector's two content families without carrying an ordinal:
/// ordinals are live stream slots, never content indices.
enum TranscriptStreamKind: Hashable, Sendable {
    case text
    case reasoning
}

enum TranscriptLiveReducer {
    static func reduce(
        messages: [TranscriptMessage],
        activeSession: SessionID,
        event: SessionTranscriptEvent
    ) -> TranscriptLiveReduction {
        guard event.sessionID == activeSession else { return .ignored }
        switch event {
        case .stepStarted(_, let messageID, let agent, let model, let started, _):
            return reduceStepStarted(messages: messages, messageID: messageID, agent: agent, model: model, started: started)
        case .stepStreamed:
            return .ignored
        case .stepEnded(_, let messageID, let finish, let created):
            return reduceStepTerminal(messages: messages, messageID: messageID, finish: finish, error: nil, created: created)
        case .stepFailed(_, let messageID, let finish, let error, let created):
            return reduceStepTerminal(messages: messages, messageID: messageID, finish: finish, error: error, created: created)
        case .textStarted, .textDelta, .reasoningStarted, .reasoningDelta,
            .toolInputDelta, .toolProgress:
            return .ignored
        case .textEnded(_, let messageID, _, _, _),
            .reasoningEnded(_, let messageID, _, _, _):
            // Ordinal is not a content index and the projector's target
            // ("latest text" / "latest reasoning without completed") cannot
            // be reproduced without applied start events.
            return .needsMessageRefresh(messageID: messageID)
        case .toolInputStarted(_, let messageID, let toolID, let name, let created):
            return reduceToolInputStarted(messages: messages, messageID: messageID, toolID: toolID, name: name, created: created)
        case .toolInputEnded(_, let messageID, let toolID, let text, _):
            return reduceToolInputEnded(messages: messages, messageID: messageID, toolID: toolID, text: text)
        case .toolCalled(_, let messageID, let toolID, let input, _):
            return reduceToolCalled(messages: messages, messageID: messageID, toolID: toolID, input: input)
        case .toolSuccess(_, let messageID, let toolID, let content, _, let metadata, _):
            return reduceToolSuccess(messages: messages, messageID: messageID, toolID: toolID, content: content, metadata: metadata)
        case .toolFailed(_, let messageID, let toolID, let error, _, let content, let metadata, _):
            return reduceToolFailed(messages: messages, messageID: messageID, toolID: toolID, error: error, content: content, metadata: metadata)
        }
    }

    /// Convenience over a decoder result. Malformed events never mutate:
    /// a usable assistant id requests a targeted refresh, otherwise a full
    /// refresh. Recognized-but-unusable and unknown types stay quiet.
    static func reduce(
        messages: [TranscriptMessage],
        activeSession: SessionID,
        decoded: SessionTranscriptDecodeResult
    ) -> TranscriptLiveReduction {
        switch decoded {
        case .notApplicable:
            return .ignored
        case .event(let event):
            return reduce(messages: messages, activeSession: activeSession, event: event)
        case .malformed(_, let assistantMessageID):
            guard let assistantMessageID, !assistantMessageID.isEmpty else {
                return .needsFullRefresh(.malformedEvent)
            }
            return .needsMessageRefresh(messageID: assistantMessageID)
        }
    }

    // MARK: - Step

    private static func reduceStepStarted(
        messages: [TranscriptMessage],
        messageID: String,
        agent: String,
        model: TranscriptModelRef,
        started: Double
    ) -> TranscriptLiveReduction {
        // A delayed start must never regress an existing (possibly terminal) row.
        guard assistantIndex(in: messages, id: messageID) == nil else { return .ignored }
        if messages.contains(where: { $0.messageID == messageID }) {
            return .needsMessageRefresh(messageID: messageID)
        }
        var next = messages
        next.append(.assistant(TranscriptAssistantMessage(
            id: messageID,
            created: started,
            completed: nil,
            agent: agent,
            model: model,
            finish: nil,
            error: nil,
            content: []
        )))
        return .applied(messages: next)
    }

    private static func reduceStepTerminal(
        messages: [TranscriptMessage],
        messageID: String,
        finish: String,
        error: TranscriptToolError?,
        created: Double
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID) else {
            // Missing assistant, or the id belongs to a non-assistant
            // (e.g. opaque) row: never invent or reinterpret it.
            return .needsMessageRefresh(messageID: messageID)
        }
        // Duplicate or late terminal: never regress or overwrite.
        guard assistant.completed == nil else { return .ignored }
        var next = messages
        next[index] = .assistant(TranscriptAssistantMessage(
            id: assistant.id,
            created: assistant.created,
            completed: created,
            agent: assistant.agent,
            model: assistant.model,
            finish: finish,
            error: error,
            content: assistant.content
        ))
        return .applied(messages: next)
    }

    // MARK: - Tools

    private static func reduceToolInputStarted(
        messages: [TranscriptMessage],
        messageID: String,
        toolID: String,
        name: String,
        created: Double
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID) else {
            return .needsMessageRefresh(messageID: messageID)
        }
        guard toolIndex(in: assistant, id: toolID) == nil else { return .ignored }
        var next = messages
        next[index] = .assistant(TranscriptAssistantMessage.withAppendedTool(
            assistant,
            TranscriptToolContent(id: toolID, name: name, created: created, state: .streaming(input: ""))
        ))
        return .applied(messages: next)
    }

    private static func reduceToolInputEnded(
        messages: [TranscriptMessage],
        messageID: String,
        toolID: String,
        text: String
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID),
              let toolPosition = toolIndex(in: assistant, id: toolID) else {
            return .needsMessageRefresh(messageID: messageID)
        }
        guard case .streaming = toolContent(in: assistant, at: toolPosition).state else {
            return .ignored
        }
        var next = messages
        next[index] = .assistant(TranscriptAssistantMessage.withReplacedTool(
            assistant,
            at: toolPosition,
            state: .streaming(input: text)
        ))
        return .applied(messages: next)
    }

    private static func reduceToolCalled(
        messages: [TranscriptMessage],
        messageID: String,
        toolID: String,
        input: TranscriptJSONValue
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID),
              let toolPosition = toolIndex(in: assistant, id: toolID) else {
            // `called` without a preceding tool start lacks the tool name;
            // never invent the row.
            return .needsMessageRefresh(messageID: messageID)
        }
        let tool = toolContent(in: assistant, at: toolPosition)
        switch tool.state {
        case .streaming:
            var next = messages
            next[index] = .assistant(TranscriptAssistantMessage.withReplacedTool(
                assistant,
                at: toolPosition,
                state: .running(input: input, metadata: .object([:]))
            ))
            return .applied(messages: next)
        case .running, .completed, .error:
            return .ignored
        }
    }

    private static func reduceToolSuccess(
        messages: [TranscriptMessage],
        messageID: String,
        toolID: String,
        content: [TranscriptToolOutput],
        metadata: TranscriptJSONValue?
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID),
              let toolPosition = toolIndex(in: assistant, id: toolID) else {
            return .needsMessageRefresh(messageID: messageID)
        }
        let tool = toolContent(in: assistant, at: toolPosition)
        switch tool.state {
        case .running(let input, _):
            var next = messages
            next[index] = .assistant(TranscriptAssistantMessage.withReplacedTool(
                assistant,
                at: toolPosition,
                state: .completed(input: input, content: content, metadata: metadata)
            ))
            return .applied(messages: next)
        case .streaming:
            // `called` was not observed, so the input object is unknown;
            // never fabricate it.
            return .needsMessageRefresh(messageID: messageID)
        case .completed, .error:
            return .ignored
        }
    }

    private static func reduceToolFailed(
        messages: [TranscriptMessage],
        messageID: String,
        toolID: String,
        error: TranscriptToolError,
        content: [TranscriptToolOutput]?,
        metadata: TranscriptJSONValue?
    ) -> TranscriptLiveReduction {
        guard let (index, assistant) = assistant(at: messages, id: messageID),
              let toolPosition = toolIndex(in: assistant, id: toolID) else {
            return .needsMessageRefresh(messageID: messageID)
        }
        let tool = toolContent(in: assistant, at: toolPosition)
        switch tool.state {
        case .streaming:
            var next = messages
            next[index] = .assistant(TranscriptAssistantMessage.withReplacedTool(
                assistant,
                at: toolPosition,
                state: .error(input: .object([:]), error: error, content: content, metadata: metadata)
            ))
            return .applied(messages: next)
        case .running(let input, _):
            var next = messages
            next[index] = .assistant(TranscriptAssistantMessage.withReplacedTool(
                assistant,
                at: toolPosition,
                state: .error(input: input, error: error, content: content, metadata: metadata)
            ))
            return .applied(messages: next)
        case .completed, .error:
            return .ignored
        }
    }

    // MARK: - Stream settlement (H08, pure)

    /// Appends the projector's empty durable slot for one observed start:
    /// `text.started` appends `{type:text,text:""}` and `reasoning.started`
    /// appends an empty reasoning item, both at the END of assistant content
    /// (verified OpenCode v2.0.20 `message-updater.ts`). Nil when the
    /// assistant row is absent (or the id belongs to a non-assistant row);
    /// the caller records nothing and reconciles instead.
    static func appendingEmptyContent(
        to messages: [TranscriptMessage],
        messageID: String,
        kind: TranscriptStreamKind
    ) -> [TranscriptMessage]? {
        guard let (index, assistant) = assistant(at: messages, id: messageID) else { return nil }
        var next = messages
        next[index] = .assistant(TranscriptAssistantMessage.withReplacedContent(
            assistant,
            assistant.content + [kind == .text ? .text("") : .reasoning("")]
        ))
        return next
    }

    /// Sets the terminal text on the LAST content item of that kind
    /// (`text.ended` targets the latest text item; `reasoning.ended` the
    /// latest reasoning item). Nil when the assistant row is absent or holds
    /// no item of that kind; the caller reconciles instead of guessing.
    /// Never equates an ordinal with an index.
    static func settingLastContentText(
        in messages: [TranscriptMessage],
        messageID: String,
        kind: TranscriptStreamKind,
        text: String
    ) -> [TranscriptMessage]? {
        guard let (index, assistant) = assistant(at: messages, id: messageID) else { return nil }
        let position: Int? = switch kind {
        case .text:
            assistant.content.lastIndex(where: { if case .text = $0 { return true }; return false })
        case .reasoning:
            assistant.content.lastIndex(where: { if case .reasoning = $0 { return true }; return false })
        }
        guard let position else { return nil }
        var content = assistant.content
        content[position] = kind == .text ? .text(text) : .reasoning(text)
        var next = messages
        next[index] = .assistant(TranscriptAssistantMessage.withReplacedContent(assistant, content))
        return next
    }

    // MARK: - Lookup
    /// Index of the `.assistant` message with this id, or nil when there is
    /// no such assistant (including when the id belongs to another variant).
    private static func assistantIndex(in messages: [TranscriptMessage], id: String) -> Int? {
        messages.firstIndex(where: {
            guard case .assistant(let assistant) = $0 else { return false }
            return assistant.id == id
        })
    }

    /// The assistant row for this id. Nil when missing or when the id belongs
    /// to a non-assistant (e.g. opaque) row, which the caller reconciles.
    private static func assistant(at messages: [TranscriptMessage], id: String) -> (Int, TranscriptAssistantMessage)? {
        guard let index = messages.firstIndex(where: { $0.messageID == id }) else { return nil }
        guard case .assistant(let assistant) = messages[index] else { return nil }
        return (index, assistant)
    }

    private static func toolIndex(in assistant: TranscriptAssistantMessage, id: String) -> Int? {
        assistant.content.firstIndex(where: {
            guard case .tool(let tool) = $0 else { return false }
            return tool.id == id
        })
    }

    private static func toolContent(in assistant: TranscriptAssistantMessage, at position: Int) -> TranscriptToolContent {
        guard case .tool(let tool) = assistant.content[position] else {
            preconditionFailure("toolIndex must only return tool positions")
        }
        return tool
    }
}

private extension TranscriptAssistantMessage {
    /// Copies this message with its content rebuilt wholesale. Only the
    /// targeted row changes; siblings and message order are untouched.
    static func withReplacedContent(_ assistant: TranscriptAssistantMessage, _ content: [TranscriptContent]) -> TranscriptAssistantMessage {
        TranscriptAssistantMessage(
            id: assistant.id,
            created: assistant.created,
            completed: assistant.completed,
            agent: assistant.agent,
            model: assistant.model,
            finish: assistant.finish,
            error: assistant.error,
            content: content
        )
    }

    /// Copies this message with one tool appended. Only the targeted row
    /// changes; siblings and message order are untouched.
    static func withAppendedTool(_ assistant: TranscriptAssistantMessage, _ tool: TranscriptToolContent) -> TranscriptAssistantMessage {
        TranscriptAssistantMessage(
            id: assistant.id,
            created: assistant.created,
            completed: assistant.completed,
            agent: assistant.agent,
            model: assistant.model,
            finish: assistant.finish,
            error: assistant.error,
            content: assistant.content + [.tool(tool)]
        )
    }

    /// Copies this message with the tool at `position` rebuilt in `state`,
    /// preserving its id, name, and creation time.
    static func withReplacedTool(
        _ assistant: TranscriptAssistantMessage,
        at position: Int,
        state: TranscriptToolState
    ) -> TranscriptAssistantMessage {
        guard case .tool(let tool) = assistant.content[position] else {
            preconditionFailure("withReplacedTool requires a tool position")
        }
        var content = assistant.content
        content[position] = .tool(TranscriptToolContent(id: tool.id, name: tool.name, created: tool.created, state: state))
        return TranscriptAssistantMessage(
            id: assistant.id,
            created: assistant.created,
            completed: assistant.completed,
            agent: assistant.agent,
            model: assistant.model,
            finish: assistant.finish,
            error: assistant.error,
            content: content
        )
    }
}
