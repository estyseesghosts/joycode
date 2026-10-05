import SwiftUI

struct SessionRenameView: View {
    @ObservedObject var store: ActiveSessionStore
    @State private var model = SessionRenameDraft(sessionID: "", authoritativeTitle: "")
    @FocusState private var focused: Bool

    private var activeTitle: String { store.activeSession?.title ?? "" }
    private var activeIDString: String { store.activeSession?.id.rawValue ?? "" }

    private var canSubmit: Bool {
        guard model.sessionID == activeIDString, model.authoritativeTitle == activeTitle else { return false }
        guard model.isEligible else { return false }
        if case .inProgress = store.renameState { return false }
        if case .checking = store.renameState { return false }
        return true
    }

    private var isBusy: Bool {
        if case .inProgress = store.renameState { return true }
        if case .checking = store.renameState { return true }
        return false
    }

    private var draftBinding: Binding<String> {
        Binding<String>(
            get: { model.text },
            set: { model.editText($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Session title", text: draftBinding)
                    .focused($focused)
                    .disabled(isBusy)
                    .onSubmit { if canSubmit { submitRename() } }
                    .onExitCommand { model.revert() }
                    .accessibilityLabel("Session title")
                    .accessibilityIdentifier("session-rename-editor")
                Button("Rename") { submitRename() }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("session-rename-submit")
            }

            if let conflict = model.conflict {
                HStack(spacing: 6) {
                    Text("Server title changed: \"\(conflict.serverTitle)\"")
                        .font(.caption)
                    Button("Use Server") { model.acceptServer() }
                        .font(.caption)
                        .disabled(isBusy)
                        .accessibilityIdentifier("session-rename-accept-server")
                    Button("Keep Edit") { model.keepEdit() }
                        .font(.caption)
                        .disabled(isBusy)
                        .accessibilityIdentifier("session-rename-keep-edit")
                }
                .accessibilityIdentifier("session-rename-conflict")
            }

            switch store.renameState {
            case .inProgress:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).accessibilityLabel("Renaming")
                    Text("Renaming…").font(.caption)
                }
                .accessibilityIdentifier("session-rename-status")
            case .checking:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking server title")
                    Text("Checking server title…").font(.caption)
                }
                .accessibilityIdentifier("session-rename-status")
            case .rejected(_, let problem, let serverTitle):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename was rejected (\(problem.label)).")
                        .font(.caption)
                    if let serverTitle {
                        Text("Server title: \(serverTitle)").font(.caption)
                    }
                }
                .accessibilityIdentifier("session-rename-status")
            case .unknown(_, let serverTitle):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename outcome unknown. Check before retrying.").font(.caption)
                    if let serverTitle {
                        Text("Server title: \(serverTitle)").font(.caption)
                    }
                    Button("Check") { store.checkRename() }
                        .accessibilityLabel("Check server title")
                        .accessibilityIdentifier("session-rename-check")
                }
                .accessibilityIdentifier("session-rename-status")
            case .idle:
                EmptyView()
            }
        }
        .onChange(of: store.state) { _, _ in
            model.sync(sessionID: activeIDString, authoritativeTitle: activeTitle)
        }
        .onChange(of: store.renameState) { _, _ in
            model.sync(sessionID: activeIDString, authoritativeTitle: activeTitle)
        }
        .onAppear {
            model = SessionRenameDraft(sessionID: activeIDString, authoritativeTitle: activeTitle)
            focused = false
        }
    }

    private func submitRename() {
        guard canSubmit else { return }
        store.rename(model.text)
    }
}
