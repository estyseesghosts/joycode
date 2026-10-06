import SwiftUI

/// Replaceable presentation seam for the initial application window.
struct RootView: View {
    let model: DiagnosticModel
    let eventOwner: ConnectionEventOwner
    let pickerModel: ProjectPickerModel
    let sessionStore: ActiveSessionStore
    let selectionStore: SelectionStore
    let composerStore: ComposerStore
    let transcriptStore: TranscriptStore
    let executionStore: ExecutionStatusStore
    let permissionStore: PermissionStore

    init(model: DiagnosticModel, eventOwner: ConnectionEventOwner, pickerModel: ProjectPickerModel, sessionStore: ActiveSessionStore, selectionStore: SelectionStore, composerStore: ComposerStore, transcriptStore: TranscriptStore, executionStore: ExecutionStatusStore, permissionStore: PermissionStore) {
        self.model = model
        self.eventOwner = eventOwner
        self.pickerModel = pickerModel
        self.sessionStore = sessionStore
        self.selectionStore = selectionStore
        self.composerStore = composerStore
        self.transcriptStore = transcriptStore
        self.executionStore = executionStore
        self.permissionStore = permissionStore
    }

    init(model: DiagnosticModel, eventOwner: ConnectionEventOwner, transport: any HTTPTransport) {
        let location = ProjectComposition.activeLocationStore(connectionOwner: model, transport: transport)
        let sessionStore = SessionComposition.activeSessionStore(connectionOwner: model, location: location, preferences: ProjectComposition.localPreferencesStore(), transport: transport)
        let selection = SelectionComposition.selectionStore(connectionOwner: model, location: location, sessionStore: sessionStore, transport: transport)
        self.init(model: model, eventOwner: eventOwner, pickerModel: ProjectPickerModel(store: location), sessionStore: sessionStore, selectionStore: selection, composerStore: ConversationComposition.composer(connectionOwner: model, sessions: sessionStore, selection: selection, transport: transport), transcriptStore: ConversationComposition.transcript(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport), executionStore: ConversationComposition.execution(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport), permissionStore: ConversationComposition.permission(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport))
    }

    var body: some View {
        HSplitView {
            VStack {
                ProjectPickerView(model: pickerModel, store: pickerModel.store)
                SessionView(store: sessionStore)
                Spacer()
                DiagnosticView(model: model, eventOwner: eventOwner)
            }
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 340)
            VStack {
                SelectionView(store: selectionStore)
                TranscriptView(store: transcriptStore)
                ExecutionStatusView(store: executionStore)
                PermissionView(store: permissionStore)
                Divider()
                ComposerView(store: composerStore)
            }
            .frame(minWidth: 400)
        }
        .accessibilityIdentifier("joycode-root")
    }
}

#Preview {
    let transport: any HTTPTransport = URLSessionHTTPTransport()
    let model = DiagnosticComposition.productionModel(transport: transport)
    RootView(model: model, eventOwner: ConnectionEventOwner(connectionOwner: model), transport: transport)
}
