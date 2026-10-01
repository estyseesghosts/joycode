import SwiftUI

/// Replaceable presentation seam for the initial application window.
struct RootView: View {
    @ObservedObject var model: DiagnosticModel

    init(model: DiagnosticModel = DiagnosticComposition.productionModel()) {
        self.model = model
    }

    var body: some View {
        DiagnosticView(model: model)
        .accessibilityIdentifier("joycode-root")
    }
}

#Preview {
    RootView()
}
