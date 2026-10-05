import SwiftUI
import UniformTypeIdentifiers

struct ProjectPickerView: View {
    @ObservedObject var model: ProjectPickerModel
    @ObservedObject var store: ActiveLocationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.state {
            case .empty:
                Text("Choose a project folder to get started."); chooseButton
            case .selected(let directory):
                Text(directory.path).accessibilityIdentifier("project-picker-location")
                Text("Not yet verified")
                Button("Verify") { model.retry() }
            case .resolving(let directory):
                ProgressView().controlSize(.small); Text(directory.path)
            case .resolved(let location):
                Text("Location: \(location.directory.path)").accessibilityIdentifier("project-picker-location")
                Text("Project: \(location.project.id.rawValue)").accessibilityIdentifier("project-picker-project")
                chooseButton(label: "Choose Different Folder…")
            case .needsRecovery(let directory, let problem):
                Text(recoveryMessage(problem)).accessibilityIdentifier("project-picker-recovery")
                if let directory { Text(directory.path).accessibilityIdentifier("project-picker-location"); Button("Verify") { model.retry() } }
                chooseButton
            }
        }
        .padding()
        .accessibilityIdentifier("project-picker")
        .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder]) { model.completeImport($0) }
        .task { model.restoreIfNeeded() }
    }

    private var chooseButton: some View { chooseButton(label: "Choose Folder…") }
    private func chooseButton(label: String) -> some View { Button(label) { model.chooseFolder() }.accessibilityIdentifier("project-picker-choose") }
    private func recoveryMessage(_ problem: ActiveLocationProblem) -> String {
        switch problem { case .directoryMissing: return "That folder is no longer available. Choose another folder."; case .notADirectory: return "The selected path is not a folder. Choose another folder."; case .directoryInaccessible: return "That folder cannot be accessed. Choose another folder or check its permissions."; case .notConnected: return "Connect to OpenCode, then choose Verify."; case .unauthorized: return "OpenCode rejected this request. Check your connection, then choose Verify."; case .malformedResponse: return "OpenCode returned an invalid location. Choose Verify again or another folder."; case .preferencesUnreadable: return "Saved folder preferences could not be read. Choose another folder."; case .requestFailed: return "The folder could not be verified. Connect to OpenCode and choose Verify again." }
    }
}
