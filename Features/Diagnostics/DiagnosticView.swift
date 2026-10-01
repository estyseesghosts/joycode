import SwiftUI

struct DiagnosticView: View {
    @ObservedObject var model: DiagnosticModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 34))
            Text(title)
                .font(.title2)
                .accessibilityIdentifier("diagnostic-status")
            detail
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isDisconnected || isFailure || isIncompatible || isUnauthorized {
                Button("Connect") { model.connect() }
                    .accessibilityIdentifier("diagnostic-connect")
            } else if isConnecting {
                Button("Cancel") { model.disconnect() }
                    .accessibilityIdentifier("diagnostic-cancel")
            } else if isConnected {
                Button("Disconnect") { model.disconnect() }
                    .accessibilityIdentifier("diagnostic-disconnect")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("diagnostic-view")
    }

    private var isDisconnected: Bool { if case .disconnected = model.status { true } else { false } }
    private var isFailure: Bool { if case .failure = model.status { true } else { false } }
    private var isIncompatible: Bool { if case .incompatible = model.status { true } else { false } }
    private var isUnauthorized: Bool { if case .unauthorized = model.status { true } else { false } }
    private var isConnected: Bool { if case .connected = model.status { true } else { false } }
    private var isConnecting: Bool { if case .connecting = model.status { true } else { false } }

    private var iconName: String {
        switch model.status { case .connected: "checkmark.circle"; case .connecting: "arrow.triangle.2.circlepath"; case .unauthorized: "lock.circle"; case .incompatible: "exclamationmark.triangle"; case .failure: "xmark.circle"; case .disconnected: "circle" }
    }

    private var title: String {
        switch model.status { case .connected: "Connected"; case .connecting: "Connecting…"; case .unauthorized: "Unauthorized"; case .incompatible: "Incompatible service"; case .failure: "Connection failed"; case .disconnected: "Disconnected" }
    }

    @ViewBuilder private var detail: some View {
        switch model.status {
        case .connected(let version): Text("Server version: \(version)")
        case .connecting: Text("Waiting for the local service")
        case .disconnected: Text("Connect when you are ready")
        case .unauthorized: Text("The local service rejected authentication")
        case .incompatible: Text("The local service is not compatible")
        case .failure: Text("The local service could not be reached")
        }
    }
}
