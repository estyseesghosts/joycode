import SwiftUI

struct SessionView: View {
    @ObservedObject var store: ActiveSessionStore
    private var createDisabled: Bool { switch store.state { case .creating, .creationUnknown, .loading: true; default: false } }
    var body: some View {
        VStack {
            if let browsing = store.browsingDirectory {
                Text("Browsing \(browsing.path)").font(.caption).accessibilityIdentifier("session-browsing-directory")
            } else {
                Text("No folder chosen").font(.caption).accessibilityIdentifier("session-browsing-directory")
            }
            switch store.state {
            case .empty: Text("No session").accessibilityIdentifier("session-status")
            case .loading, .creating: ProgressView().accessibilityIdentifier("session-status")
            case .loaded(let session): Text(session.title).accessibilityIdentifier("session-title"); Text(session.directory.path).font(.caption).accessibilityIdentifier("session-active-directory")
            case .failed: Text("Unable to load session").accessibilityIdentifier("session-status")
            case .creationRejected: Text("Session creation was rejected").accessibilityIdentifier("session-status")
            case .creationUnknown: Text("Creation outcome unknown; checking will not duplicate it.").accessibilityIdentifier("session-status"); Button("Check") { store.recoverUnknownCreation() }.accessibilityIdentifier("session-recover")
            }
            if store.activeSession != nil { SessionRenameView(store: store) }
            if !store.roots.isEmpty {
                ScrollView {
                    ForEach(store.roots, id: \.id.rawValue) { root in
                        Button(root.title) { store.selectRoot(root.id) }
                            .disabled({ switch store.state { case .creating, .creationUnknown: true; default: false } }())
                            .accessibilityIdentifier("session-root")
                            .accessibilityValue(root.id == store.activeSession?.id ? "selected" : "not-selected")
                    }
                }
                .frame(maxHeight: 140)
                .accessibilityIdentifier("session-roots")
            }
            HStack { Button("Create") { store.create() }.disabled(createDisabled).accessibilityIdentifier("session-create"); Button("Refresh") { store.refreshRoots() }.disabled(store.state == .creating).accessibilityIdentifier("session-refresh") }
        }.accessibilityIdentifier("session-view").task { store.restoreIfNeeded() }
    }
}
