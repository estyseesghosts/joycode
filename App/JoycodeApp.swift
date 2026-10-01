import SwiftUI

@main
struct JoycodeApp: App {
    @State private var diagnosticModel = DiagnosticComposition.productionModel()

    var body: some Scene {
        WindowGroup("Joycode") {
            RootView(model: diagnosticModel)
        }
        .defaultSize(width: 900, height: 600)
    }
}
