import Foundation
import XCTest
@testable import Joycode

final class LocalPreferencesStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Joycode-LocalPreferences-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripAndMissingFileUseDefaults() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        XCTAssertEqual(try store.load(), .default)

        let preferences = LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/example"))
        try store.save(preferences)
        XCTAssertEqual(try store.load(), preferences)
    }

    func testVersionTwoRoundTripIncludesLastSessionID() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        let value = LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/example"), lastSessionID: SessionID(rawValue: "ses-1"))
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
    }

    func testVersionOneMigratesInMemoryAndHasNoLastSessionID() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        try Data(#"{"schemaVersion":1,"selectedDirectoryPath":"/tmp/legacy"}"#.utf8).write(to: store.fileURL)
        let value = try store.load()
        XCTAssertEqual(value.selectedDirectory?.path, "/tmp/legacy")
        XCTAssertNil(value.lastSessionID)
    }

    func testSaveReplacesAtomicallyAndLeavesNoTemporaryFiles() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        try store.save(LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/old")))
        try store.save(LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/new")))

        XCTAssertEqual(try store.load().selectedDirectory?.path, "/tmp/new")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["local-preferences.json"])
    }

    func testReplacementFailureLeavesPriorPreferencesRecoverable() throws {
        let fileURL = directory.appendingPathComponent("local-preferences.json")
        let oldPreferences = LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/old"))
        let store = LocalPreferencesStore(fileURL: fileURL)
        try store.save(oldPreferences)

        let failingStore = LocalPreferencesStore(fileURL: fileURL) { _, _ in
            throw CommitFailure.injected
        }

        XCTAssertThrowsError(try failingStore.save(
            LocalPreferences(selectedDirectory: URL(fileURLWithPath: "/tmp/new"))
        )) { error in
            XCTAssertEqual(error as? CommitFailure, .injected)
        }
        XCTAssertEqual(try store.load(), oldPreferences)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["local-preferences.json"]
        )
    }

    func testCorruptDataIsAnErrorAndDoesNotDeleteTheFile() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        try Data("not json".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LocalPreferencesStoreError, .corruptData)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("not json".utf8))
    }

    func testNewerSchemaIsRejectedWithoutDeletingData() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        let data = Data(#"{"schemaVersion":99,"selectedDirectoryPath":"/tmp/future"}"#.utf8)
        try data.write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? LocalPreferencesStoreError, .unsupportedSchemaVersion(99))
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), data)
    }

    func testVersionZeroIsMigratedInMemory() throws {
        let store = LocalPreferencesStore(baseDirectory: directory)
        let oldData = Data(#"{"selectedDirectoryPath":"/tmp/legacy"}"#.utf8)
        try oldData.write(to: store.fileURL)

        XCTAssertEqual(try store.load().selectedDirectory?.path, "/tmp/legacy")
    }

    private enum CommitFailure: Error, Equatable {
        case injected
    }
}
