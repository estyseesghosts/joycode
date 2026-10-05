import Foundation
import CryptoKit

/// The only provenance categories accepted by the fixture loader.
public enum FixtureProvenance: String, Codable, Sendable {
    case synthetic
    case releasePinnedSanitizedCapture = "release-pinned-sanitized-capture"
}

public struct FixtureMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let pinnedRelease = "v2.0.20"

    public let schemaVersion: Int
    public let release: String
    public let operation: String
    public let provenance: FixtureProvenance
    public let sanitized: Bool
    /// Present only for an approved, real capture. It is never a filesystem path.
    public let captureID: String?

    public init(
        schemaVersion: Int = FixtureMetadata.currentSchemaVersion,
        release: String,
        operation: String,
        provenance: FixtureProvenance,
        sanitized: Bool,
        captureID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.release = release
        self.operation = operation
        self.provenance = provenance
        self.sanitized = sanitized
        self.captureID = captureID
    }

    fileprivate func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw FixtureError.schemaMismatch(expected: Self.currentSchemaVersion, actual: schemaVersion)
        }
        guard !release.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FixtureError.invalidMetadata("release and operation are required")
        }
        guard release == Self.pinnedRelease else {
            throw FixtureError.incompatibleRelease(expected: Self.pinnedRelease, actual: release)
        }
        guard sanitized else {
            throw FixtureError.invalidMetadata("all fixtures must be sanitized")
        }
        switch provenance {
        case .synthetic:
            guard captureID == nil else {
                throw FixtureError.invalidMetadata("synthetic fixtures must be sanitized and cannot have capture provenance")
            }
        case .releasePinnedSanitizedCapture:
            guard let captureID, Self.isOpaqueCaptureID(captureID) else {
                throw FixtureError.invalidMetadata(
                    "release-pinned captures require sanitized=true and an opaque captureID"
                )
            }
        }
    }

    private static func isOpaqueCaptureID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
            && !value.contains("/") && !value.contains("\\")
            && value != "." && value != ".."
    }

}

/// The reviewed release-pinned capture registry, tied to exact fixture bytes.
public enum FixtureCaptureManifest {
    public struct Entry: Codable, Equatable, Sendable {
        public let captureID: String
        public let release: String
        public let operation: String
        public let contentSHA256: String

        public init(captureID: String, release: String, operation: String, contentSHA256: String) {
            self.captureID = captureID
            self.release = release
            self.operation = operation
            self.contentSHA256 = contentSHA256
        }
    }

    public static let reviewed: [Entry] = [
        Entry(captureID: "p0-v2.0.20-server-info-20261001", release: "v2.0.20", operation: "server-info", contentSHA256: "890db671f567e8e52b552b6f3969fdab2182f4af694741543456b651caf963a7"),
        Entry(captureID: "p0-v2.0.20-server-connected-20261001", release: "v2.0.20", operation: "event-server-connected", contentSHA256: "5f800722364e6f119d716f52d72c8e1542cec925d14a0fbbc2f32e61d6462d85")
    ]

    fileprivate static func entry(
        captureID: String,
        release: String,
        operation: String,
        in manifest: [Entry]
    ) -> Entry? {
        manifest.first {
            $0.captureID == captureID && $0.release == release &&
            $0.operation == operation
        }
    }
}

public struct FixtureEnvelope<Payload: Decodable>: Decodable, Sendable where Payload: Sendable {
    public let metadata: FixtureMetadata
    public let payload: Payload
}

public enum FixtureError: Error, Equatable, CustomStringConvertible, Sendable {
    case missing(URL)
    case unreadable(URL)
    case invalidJSON
    case invalidEnvelope(String)
    case invalidMetadata(String)
    case schemaMismatch(expected: Int, actual: Int)
    case incompatibleOperation(expected: String, actual: String)
    case incompatibleRelease(expected: String, actual: String)
    case unreviewedCapture(String)
    case contentDigestMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .missing(let url): return "Fixture is missing: \(url.lastPathComponent)"
        case .unreadable(let url): return "Fixture is unreadable: \(url.lastPathComponent)"
        case .invalidJSON: return "Fixture JSON is invalid"
        case .invalidEnvelope(let reason): return "Fixture envelope is invalid: \(reason)"
        case .invalidMetadata(let reason): return "Fixture metadata is invalid: \(reason)"
        case .schemaMismatch(let expected, let actual):
            return "Fixture schema mismatch: expected \(expected), got \(actual)"
        case .incompatibleOperation(let expected, let actual):
            return "Fixture operation mismatch: expected \(expected), got \(actual)"
        case .incompatibleRelease(let expected, let actual):
            return "Fixture release mismatch: expected \(expected), got \(actual)"
        case .unreviewedCapture(let captureID): return "Fixture capture is not reviewed: \(captureID)"
        case .contentDigestMismatch(let expected, let actual):
            return "Fixture content digest mismatch: expected \(expected), got \(actual)"
        }
    }
}

public enum FixtureLoader {
    public static let defaultRelease = FixtureMetadata.pinnedRelease

    public static func load<Payload: Decodable & Sendable>(
        data: Data,
        from source: URL = URL(fileURLWithPath: "fixture.json"),
        operation: String? = nil,
        release: String = FixtureLoader.defaultRelease,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FixtureEnvelope<Payload> {
        try load(
            data: data,
            from: source,
            operation: operation,
            release: release,
            decoder: decoder,
            manifest: FixtureCaptureManifest.reviewed
        )
    }

    /// Test-only injection of an in-memory manifest. Production callers use
    /// the overload above, which always uses the immutable reviewed registry.
    internal static func load<Payload: Decodable & Sendable>(
        data: Data,
        from source: URL = URL(fileURLWithPath: "fixture.json"),
        operation: String? = nil,
        release: String = FixtureLoader.defaultRelease,
        decoder: JSONDecoder = JSONDecoder(),
        manifest: [FixtureCaptureManifest.Entry]
    ) throws -> FixtureEnvelope<Payload> {
        let fixture: FixtureEnvelope<Payload>
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FixtureError.invalidJSON
        }
        guard object is [String: Any] else {
            throw FixtureError.invalidEnvelope("top-level JSON must be an object")
        }
        do {
            fixture = try decoder.decode(FixtureEnvelope<Payload>.self, from: data)
        } catch let error as FixtureError {
            throw error
        } catch {
            throw FixtureError.invalidEnvelope(String(describing: error))
        }
        try fixture.metadata.validate()
        if let operation, operation != fixture.metadata.operation {
            throw FixtureError.incompatibleOperation(expected: operation, actual: fixture.metadata.operation)
        }
        if release != fixture.metadata.release {
            throw FixtureError.incompatibleRelease(expected: release, actual: fixture.metadata.release)
        }
        if fixture.metadata.provenance == .releasePinnedSanitizedCapture {
            guard let manifestEntry = FixtureCaptureManifest.entry(
                captureID: fixture.metadata.captureID!,
                release: fixture.metadata.release,
                operation: fixture.metadata.operation,
                in: manifest
            ) else {
                throw FixtureError.unreviewedCapture(fixture.metadata.captureID!)
            }
            let actualDigest = contentSHA256(for: data)
            guard manifestEntry.contentSHA256 == actualDigest else {
                throw FixtureError.contentDigestMismatch(expected: manifestEntry.contentSHA256, actual: actualDigest)
            }
        }
        return fixture
    }

    public static func load<Payload: Decodable & Sendable>(
        from url: URL,
        operation: String? = nil,
        release: String = FixtureLoader.defaultRelease,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> FixtureEnvelope<Payload> {
        guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.missing(url) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw FixtureError.unreadable(url) }
        return try load(data: data, from: url, operation: operation, release: release, decoder: decoder)
    }

    static func contentSHA256(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
