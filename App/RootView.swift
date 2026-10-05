import SwiftUI

/// Replaceable presentation seam for the initial application window.
struct RootView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var eventOwner: ConnectionEventOwner
    @ObservedObject var pickerModel: ProjectPickerModel
    @ObservedObject var sessionStore: ActiveSessionStore
    @ObservedObject var selectionStore: SelectionStore
    @ObservedObject var composerStore: ComposerStore
    @ObservedObject var transcriptStore: TranscriptStore
    @ObservedObject var executionStore: ExecutionStatusStore
    @ObservedObject var permissionStore: PermissionStore

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

    init(model: DiagnosticModel, eventOwner: ConnectionEventOwner) {
        let location = ProjectComposition.activeLocationStore(connectionOwner: model)
        let sessionStore = SessionComposition.activeSessionStore(connectionOwner: model, location: location, preferences: ProjectComposition.localPreferencesStore())
        let selection = SelectionComposition.selectionStore(connectionOwner: model, location: location, sessionStore: sessionStore)
        self.init(model: model, eventOwner: eventOwner, pickerModel: ProjectPickerModel(store: location), sessionStore: sessionStore, selectionStore: selection, composerStore: ConversationComposition.composer(connectionOwner: model, sessions: sessionStore, selection: selection), transcriptStore: ConversationComposition.transcript(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner), executionStore: ConversationComposition.execution(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner), permissionStore: ConversationComposition.permission(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner))
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
                SelectionView(store: selectionStore, sessionStore: sessionStore, locationStore: pickerModel.store)
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
    let model = DiagnosticComposition.productionModel()
    RootView(model: model, eventOwner: ConnectionEventOwner(connectionOwner: model))
}
