import Foundation

struct PresentationState: Sendable, Equatable {
    let title: String
    let locationID: LocationID?
    /// The selected directory is explicit and is not encoded in LocationID.
    let selectedDirectory: URL?

    init(title: String, locationID: LocationID? = nil, selectedDirectory: URL? = nil) {
        self.title = title
        self.locationID = locationID
        self.selectedDirectory = selectedDirectory
    }
}

enum PresentationAction: Sendable, Equatable {
    case selectDirectory(URL)
    case selectWorkspace(WorkspaceID)
    case selectTab(TabID)
}

protocol PresentationActionSink: Sendable {
    func send(_ action: PresentationAction)
}
