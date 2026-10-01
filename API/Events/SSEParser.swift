import Foundation

enum SSEParserError: Error, Sendable, Equatable { case lineTooLarge, eventTooLarge, invalidUTF8, malformedJSON, unterminatedFrame }

struct SSEParser: Sendable {
    let maxLineBytes: Int
    let maxEventBytes: Int
    private var line = Data()
    private var event = Data()
    private var sawData = false
    private var pendingCR = false

    init(maxLineBytes: Int = 64 * 1024, maxEventBytes: Int = 1024 * 1024) {
        self.maxLineBytes = maxLineBytes; self.maxEventBytes = maxEventBytes
    }

    mutating func append(_ bytes: Data) throws -> [EventEnvelope] {
        var result = [EventEnvelope]()
        for byte in bytes {
            if pendingCR { pendingCR = false; if byte == 10 { try finishLine(&result); continue }; try finishLine(&result) }
            if byte == 13 { pendingCR = true }
            else if byte == 10 { try finishLine(&result) }
            else { line.append(byte); if line.count > maxLineBytes { throw SSEParserError.lineTooLarge } }
        }
        return result
    }

    mutating func finish() throws -> [EventEnvelope] {
        var result = [EventEnvelope]()
        if pendingCR { pendingCR = false; try finishLine(&result) }
        if !line.isEmpty { try finishLine(&result) }
        // An SSE event is dispatched only by an empty line. EOF is not an
        // implicit frame delimiter; otherwise a truncated response could be
        // presented as a valid event.
        if sawData { throw SSEParserError.unterminatedFrame }
        return result
    }

    private mutating func finishLine(_ result: inout [EventEnvelope]) throws {
        defer { line.removeAll(keepingCapacity: true) }
        guard let text = String(data: line, encoding: .utf8) else { throw SSEParserError.invalidUTF8 }
        if text.isEmpty { if sawData { try dispatch(&result) }; return }
        if text.first == ":" { return }
        guard text.hasPrefix("data:") else { return } // V2 has no id/event fields; ignore unknown SSE fields safely.
        var value = String(text.dropFirst(5)); if value.first == " " { value.removeFirst() }
        let data = Data(value.utf8)
        if !event.isEmpty { event.append(10) }
        event.append(data); sawData = true
        if event.count > maxEventBytes { throw SSEParserError.eventTooLarge }
    }

    private mutating func dispatch(_ result: inout [EventEnvelope]) throws {
        defer { event.removeAll(keepingCapacity: true); sawData = false }
        guard let decoded = try? JSONDecoder().decode(EventEnvelope.self, from: event) else { throw SSEParserError.malformedJSON }
        result.append(decoded)
    }
}
