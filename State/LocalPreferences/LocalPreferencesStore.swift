import Foundation

/// UI-only values that may be retained between launches.
///
/// This type deliberately has no OpenCode messages, credentials, provider
/// configuration, or session data. Constructing a store is side-effect free;
/// callers choose when to load or save it.
struct LocalPreferences: Codable, Equatable, Sendable {
    var selectedDirectory: URL?

    static let `default` = LocalPreferences(selectedDirectory: nil)
}

enum LocalPreferencesStoreError: Error, Equatable {
    case corruptData
    case unsupportedSchemaVersion(Int)
}

/// File-backed, versioned preferences for local presentation state.
///
/// The current disk schema is version 1. Version 0 (which used the same
/// directory field but did not require a version marker) is read and migrated
/// in memory. A newer version and malformed data are errors: loading never
/// replaces or deletes the user's file, so a future client can recover it.
struct LocalPreferencesStore: Sendable {
    let fileURL: URL
    private let replaceItem: @Sendable (URL, URL) throws -> Void

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.replaceItem = { existingURL, temporaryURL in
            _ = try FileManager.default.replaceItemAt(existingURL, withItemAt: temporaryURL)
        }
    }

    /// Internal seam for exercising failures while committing a replacement.
    init(fileURL: URL, replacingItem: @escaping @Sendable (URL, URL) throws -> Void) {
        self.fileURL = fileURL
        self.replaceItem = replacingItem
    }

    init(baseDirectory: URL, fileName: String = "local-preferences.json") {
        self.init(fileURL: baseDirectory.appendingPathComponent(fileName, isDirectory: false))
    }

    func load() throws -> LocalPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .default
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw error
        }

        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LocalPreferencesStoreError.corruptData
            }
            object = decoded
        } catch let error as LocalPreferencesStoreError {
            throw error
        } catch {
            throw LocalPreferencesStoreError.corruptData
        }

        if object.keys.contains("schemaVersion") {
            guard let version = object["schemaVersion"] as? Int, version >= 0 else {
                throw LocalPreferencesStoreError.corruptData
            }
            guard version <= Self.currentSchemaVersion else {
                throw LocalPreferencesStoreError.unsupportedSchemaVersion(version)
            }
            if version == 0 {
                return try decodeVersionZero(data)
            }
            do {
                return try JSONDecoder().decode(DiskPreferencesV1.self, from: data).preferences
            } catch {
                throw LocalPreferencesStoreError.corruptData
            }
        }

        do {
            return try JSONDecoder().decode(DiskPreferencesV1.self, from: data).preferences
        } catch {
            // A missing schema marker is the supported v0 shape. It is
            // intentionally decoded only after the current shape fails.
            return try decodeVersionZero(data)
        }
    }

    func save(_ preferences: LocalPreferences) throws {
        let data = try JSONEncoder().encode(DiskPreferencesV1(preferences: preferences))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try replaceItem(fileURL, temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    private func decodeVersionZero(_ data: Data) throws -> LocalPreferences {
        do {
            return try JSONDecoder().decode(DiskPreferencesV0.self, from: data).preferences
        } catch {
            throw LocalPreferencesStoreError.corruptData
        }
    }

    private static let currentSchemaVersion = 1

    private struct DiskPreferencesV1: Codable {
        let schemaVersion: Int
        let selectedDirectoryPath: String?

        init(preferences: LocalPreferences) {
            schemaVersion = currentSchemaVersion
            selectedDirectoryPath = preferences.selectedDirectory?.path
        }

        var preferences: LocalPreferences {
            LocalPreferences(selectedDirectory: selectedDirectoryPath.map(URL.init(fileURLWithPath:)))
        }
    }

    private struct DiskPreferencesV0: Codable {
        let selectedDirectoryPath: String?

        var preferences: LocalPreferences {
            LocalPreferences(selectedDirectory: selectedDirectoryPath.map(URL.init(fileURLWithPath:)))
        }
    }
}
