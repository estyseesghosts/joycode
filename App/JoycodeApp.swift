import SwiftUI

@main
struct JoycodeApp: App {
    private let diagnosticModel: DiagnosticModel
    private let eventOwner: ConnectionEventOwner
    private let pickerModel: ProjectPickerModel
    private let sessionStore: ActiveSessionStore
    private let selectionStore: SelectionStore
    private let composerStore: ComposerStore
    private let transcriptStore: TranscriptStore
    private let executionStore: ExecutionStatusStore
    private let permissionStore: PermissionStore

    init() {
        let resolved = Self.makeStores()
        diagnosticModel = resolved.model
        eventOwner = resolved.eventOwner
        pickerModel = resolved.pickerModel
        sessionStore = resolved.sessionStore
        selectionStore = resolved.selectionStore
        composerStore = resolved.composerStore
        transcriptStore = resolved.transcriptStore
        executionStore = resolved.executionStore
        permissionStore = resolved.permissionStore
    }

    var body: some Scene {
        Window("Joycode", id: "joycode-main") {
            RootView(model: diagnosticModel, eventOwner: eventOwner, pickerModel: pickerModel, sessionStore: sessionStore, selectionStore: selectionStore, composerStore: composerStore, transcriptStore: transcriptStore, executionStore: executionStore, permissionStore: permissionStore)
        }
        .defaultSize(width: 1000, height: 750)
    }

    @MainActor
    private static func makeStores() -> (
        model: DiagnosticModel,
        eventOwner: ConnectionEventOwner,
        pickerModel: ProjectPickerModel,
        sessionStore: ActiveSessionStore,
        selectionStore: SelectionStore,
        composerStore: ComposerStore,
        transcriptStore: TranscriptStore,
        executionStore: ExecutionStatusStore,
        permissionStore: PermissionStore
    ) {
#if DEBUG
        if OfflineUITestComposition.isEnabled {
            return OfflineUITestComposition.build()
        }
#endif
        return makeProductionStores()
    }

    @MainActor
    private static func makeProductionStores() -> (
        model: DiagnosticModel,
        eventOwner: ConnectionEventOwner,
        pickerModel: ProjectPickerModel,
        sessionStore: ActiveSessionStore,
        selectionStore: SelectionStore,
        composerStore: ComposerStore,
        transcriptStore: TranscriptStore,
        executionStore: ExecutionStatusStore,
        permissionStore: PermissionStore
    ) {
        let transport: any HTTPTransport = URLSessionHTTPTransport()
        let model = DiagnosticComposition.productionModel(transport: transport)
        let eventOwner = ConnectionEventOwner(connectionOwner: model)
        let location = ProjectComposition.activeLocationStore(connectionOwner: model, transport: transport)
        let pickerModel = ProjectPickerModel(store: location)
        let sessionStore = SessionComposition.activeSessionStore(connectionOwner: model, location: location, preferences: ProjectComposition.localPreferencesStore(), transport: transport)
        let selectionStore = SelectionComposition.selectionStore(connectionOwner: model, location: location, sessionStore: sessionStore, transport: transport)
        return (model, eventOwner, pickerModel, sessionStore, selectionStore,
                ConversationComposition.composer(connectionOwner: model, sessions: sessionStore, selection: selectionStore, transport: transport),
                ConversationComposition.transcript(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport),
                ConversationComposition.execution(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport),
                ConversationComposition.permission(connectionOwner: model, sessions: sessionStore, eventOwner: eventOwner, transport: transport))
    }
}
