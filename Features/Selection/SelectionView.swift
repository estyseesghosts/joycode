import SwiftUI

/// Plain, replaceable selection controls for the primary agent and model.
/// Phase 5 owns styling; this view only reflects store state and forwards
/// explicit user intent (pickers, Refresh, Check, Retry) to the store. It
/// issues no automatic reads: the composition-owned store binding owns
/// session/location/connection observation, so correctness never depends on
/// view lifetime. It never builds requests or invents selections.
struct SelectionView: View {
    @ObservedObject var store: SelectionStore
    // Retained for source compatibility with production call sites; the view
    // no longer observes them. Session/location observation lives in the
    // store binding owned by SelectionComposition.
    @ObservedObject var sessionStore: ActiveSessionStore
    @ObservedObject var locationStore: ActiveLocationStore

    private var isDiscovering: Bool {
        store.agentDiscovery == .loading || store.modelDiscovery == .loading
    }

    private var isAgentBusy: Bool {
        if case .inProgress = store.agentSelection { return true }
        return false
    }

    private var isModelBusy: Bool {
        if case .inProgress = store.modelSelection { return true }
        return false
    }

    private var agentBinding: Binding<String> {
        Binding(
            get: { store.selectedAgent ?? "" },
            set: { value in if !value.isEmpty { store.selectAgent(value) } }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { store.selectedModel.map { "\($0.providerID)/\($0.id)" } ?? "" },
            set: { key in
                guard let model = store.selectableModels.first(where: { $0.id == key }) else { return }
                store.selectModel(model.ref)
            }
        )
    }

    private var hasUnknownSelection: Bool {
        if case .unknown = store.agentSelection { return true }
        if case .unknown = store.modelSelection { return true }
        return false
    }

    private func isRetryable(_ problem: SelectionProblem) -> Bool {
        switch problem {
        case .unavailable, .noSession, .noLocation: return false
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent and model").font(.caption).foregroundStyle(.secondary)
            Text("Catalog: \(store.catalogDirectory?.path ?? "none")")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("selection-catalog-directory")
            agentControls
            modelControls
            if let problem = store.hydrationProblem {
                HStack(spacing: 4) {
                    Text("Couldn't read this session's selection (\(problem.label)).").font(.caption)
                    Button("Retry") { store.retryHydration() }
                        .accessibilityLabel("Retry reading session selection")
                        .accessibilityIdentifier("selection-hydration-retry")
                }
                .accessibilityIdentifier("selection-hydration-status")
            }
            HStack(spacing: 8) {
                Button("Refresh") { store.discover() }
                    .disabled(isDiscovering)
                    .accessibilityIdentifier("selection-refresh")
                if hasUnknownSelection {
                    Button("Check") { store.checkSelection() }
                        .disabled(store.isChecking)
                        .accessibilityIdentifier("selection-check")
                    if store.isChecking {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking selection")
                    }
                }
            }
        }
        .accessibilityIdentifier("selection-view")
    }

    @ViewBuilder private var agentControls: some View {
        switch store.agentDiscovery {
        case .idle:
            Text("Agents not loaded.").font(.caption).accessibilityIdentifier("selection-agent-discovery")
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).accessibilityLabel("Loading agents")
                Text("Loading agents…").font(.caption)
            }
            .accessibilityIdentifier("selection-agent-discovery")
        case .failed(let problem):
            Text("Agents unavailable (\(problem.label)).")
                .font(.caption)
                .accessibilityIdentifier("selection-agent-discovery")
        case .loaded:
            if store.primaryAgents.isEmpty {
                Text("No primary agents available.")
                    .font(.caption)
                    .accessibilityIdentifier("selection-agent-discovery")
            } else {
                Picker("Agent", selection: agentBinding) {
                    if store.selectedAgent == nil {
                        Text("Select agent").tag("")
                    }
                    ForEach(store.primaryAgents) { agent in
                        Text(agent.name).tag(agent.id)
                    }
                }
                .frame(maxWidth: 280)
                .disabled(isAgentBusy)
                .accessibilityLabel("Primary agent")
                .accessibilityIdentifier("selection-agent-picker")
            }
        }
        agentSelectionStatus
    }

    @ViewBuilder private var agentSelectionStatus: some View {
        switch store.agentSelection {
        case .idle:
            EmptyView()
        case .inProgress:
            Text("Switching agent…").font(.caption).accessibilityIdentifier("selection-agent-status")
        case .rejected(let agent, let problem):
            HStack(spacing: 4) {
                Text("Agent selection rejected (\(problem.label)).").font(.caption)
                if isRetryable(problem) {
                    Button("Retry") { store.selectAgent(agent) }
                        .accessibilityLabel("Retry agent selection")
                        .accessibilityIdentifier("selection-agent-retry")
                }
            }
            .accessibilityIdentifier("selection-agent-status")
        case .unknown(_, let problem):
            Text("Agent selection unconfirmed (\(problem.label)).").font(.caption).accessibilityIdentifier("selection-agent-status")
        }
    }

    @ViewBuilder private var modelControls: some View {
        switch store.modelDiscovery {
        case .idle:
            Text("Models not loaded.").font(.caption).accessibilityIdentifier("selection-model-discovery")
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).accessibilityLabel("Loading models")
                Text("Loading models…").font(.caption)
            }
            .accessibilityIdentifier("selection-model-discovery")
        case .failed(let problem):
            Text("Models unavailable (\(problem.label)).")
                .font(.caption)
                .accessibilityIdentifier("selection-model-discovery")
        case .loaded:
            if store.selectableModels.isEmpty {
                Text("No models available.")
                    .font(.caption)
                    .accessibilityIdentifier("selection-model-discovery")
            } else {
                Picker("Model", selection: modelBinding) {
                    if store.selectedModel == nil {
                        Text("Select model").tag("")
                    }
                    ForEach(store.selectableModels) { model in
                        Text("\(model.name) (\(model.providerID))").tag(model.id)
                    }
                }
                .frame(maxWidth: 280)
                .disabled(isModelBusy)
                .accessibilityLabel("Model")
                .accessibilityIdentifier("selection-model-picker")
            }
        }
        modelSelectionStatus
    }

    @ViewBuilder private var modelSelectionStatus: some View {
        switch store.modelSelection {
        case .idle:
            EmptyView()
        case .inProgress:
            Text("Switching model…").font(.caption).accessibilityIdentifier("selection-model-status")
        case .rejected(let model, let problem):
            HStack(spacing: 4) {
                Text("Model selection rejected (\(problem.label)).").font(.caption)
                if isRetryable(problem) {
                    Button("Retry") { store.selectModel(model) }
                        .accessibilityLabel("Retry model selection")
                        .accessibilityIdentifier("selection-model-retry")
                }
            }
            .accessibilityIdentifier("selection-model-status")
        case .unknown(_, let problem):
            Text("Model selection unconfirmed (\(problem.label)).").font(.caption).accessibilityIdentifier("selection-model-status")
        }
    }
}
