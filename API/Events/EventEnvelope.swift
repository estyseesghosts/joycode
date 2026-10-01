import Foundation

/// JSON values preserve unknown V2 event families without interpreting them.
enum EventJSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([EventJSONValue]), object([String: EventJSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([EventJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: EventJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}

struct EventDurability: Codable, Sendable, Equatable {
    let aggregateID: String
    let seq: Int
    let version: Int
}

struct EventEnvelope: Codable, Sendable, Equatable {
    let id: String
    let type: String
    let created: Double?
    let data: EventJSONValue
    let location: EventJSONValue?
    let metadata: EventJSONValue?
    let durable: EventDurability?

    private enum CodingKeys: String, CodingKey {
        case id, type, created, data, location, metadata, durable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        if type == "server.connected" {
            created = try Self.decodeFiniteOptionalDouble(from: container, forKey: .created)
        } else {
            // All ordinary V2 events carry created; only server.connected omits it.
            created = try Self.decodeFiniteRequiredDouble(from: container, forKey: .created)
        }
        data = try container.decode(EventJSONValue.self, forKey: .data)
        location = try container.decodeIfPresent(EventJSONValue.self, forKey: .location)
        metadata = try container.decodeIfPresent(EventJSONValue.self, forKey: .metadata)
        durable = try container.decodeIfPresent(EventDurability.self, forKey: .durable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encode(data, forKey: .data)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(durable, forKey: .durable)
    }

    private static func decodeFiniteRequiredDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Double {
        let value = try container.decode(Double.self, forKey: key)
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "created must be finite"
            )
        }
        return value
    }

    private static func decodeFiniteOptionalDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Double? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        return try decodeFiniteRequiredDouble(from: container, forKey: key)
    }
}
