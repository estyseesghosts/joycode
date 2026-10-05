import SwiftUI

/// Detached composer boundary: multiline draft editor with send/status.
///
/// Presentation only. It observes `ComposerStore` and never constructs API
/// requests, owns transcripts, or promises backend cancellation: there is no
/// cancel control because the client cannot prove a dispatched prompt stopped.
/// Unavailable readiness and unknown outcomes are shown as visible status text
/// rather than silent disabled controls. Deliberately plain multiline
/// `TextEditor` (no Phase 5 polish: no attachments, steering, queues, or
/// completion) so the R06 send/disabled/submitting/error contract stays
/// testable in isolation.
struct ComposerView: View {
    @ObservedObject var store: ComposerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: draftBinding)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("composer-editor")
                .frame(minHeight: 72, maxHeight: 110)
            if let status = store.statusMessage {
                Text(status)
                    .font(.caption)
                    .accessibilityIdentifier("composer-status")
            }
            HStack(spacing: 8) {
                Button("Send") {
                    store.send()
                }
                .disabled(!store.canSend)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("composer-send")
                if store.showsRetry {
                    Button("Retry") {
                        store.retry()
                    }
                    .disabled(!store.canSend)
                    .accessibilityLabel("Retry send")
                    .accessibilityIdentifier("composer-retry")
                }
            }
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { store.draftText },
            set: { store.editText($0) }
        )
    }
}
