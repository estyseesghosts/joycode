import Foundation
import Combine

@MainActor
final class ProjectPickerModel: ObservableObject {
    let store: ActiveLocationStore
    @Published var isImporterPresented = false
    private var hasRestored = false

    init(store: ActiveLocationStore) { self.store = store }
    func chooseFolder() { isImporterPresented = true }
    func completeImport(_ result: Result<URL, Error>) {
        isImporterPresented = false
        if case .success(let url) = result { store.select(url) }
    }
    func retry() { store.retry() }
    func clear() { store.clear() }
    func restoreIfNeeded() { guard !hasRestored else { return }; hasRestored = true; store.restore() }
}
