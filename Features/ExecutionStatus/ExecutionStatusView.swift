import SwiftUI

/// Presentation only. The application composition owns all event/context bindings.
struct ExecutionStatusView: View {
    @ObservedObject var store: ExecutionStatusStore

    var body: some View {
        HStack(spacing: 8) {
            Text("Execution: \(store.statusLabel)")
                .font(.caption.weight(.medium))
            if !store.statusReason.isEmpty {
                Text(store.statusReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Refresh status") { store.refresh() }
                .accessibilityLabel("Refresh execution status")
            Button("Interrupt") { store.interrupt() }
                .disabled(!store.canInterrupt)
                .accessibilityLabel("Interrupt execution")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
