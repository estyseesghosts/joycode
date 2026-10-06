import Foundation

enum ProjectComposition {
    @MainActor static func localPreferencesStore() -> LocalPreferencesStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Joycode", isDirectory: true)
        return LocalPreferencesStore(baseDirectory: base)
    }
    @MainActor
    static func activeLocationStore(connectionOwner: ServiceConnectionOwner, transport: any HTTPTransport) -> ActiveLocationStore {
        let preferences = localPreferencesStore()
        return ActiveLocationStore(preferences: preferences) { directory in
            guard let context = await MainActor.run(body: { connectionOwner.currentContext }) else { throw LocationResolutionError.notConnected }
            let info = try await LocationResolver(transport: transport).resolve(connection: context.connection, directory: directory)
            return ResolvedLocation(directory: URL(fileURLWithPath: info.directory), project: ProjectIdentity(id: ProjectID(rawValue: info.project.id), directory: URL(fileURLWithPath: info.project.directory), canonical: URL(fileURLWithPath: info.project.canonical)))
        }
    }
}
