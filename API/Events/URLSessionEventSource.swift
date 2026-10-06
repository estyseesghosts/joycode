import Foundation

enum EventSourceError: Error, Sendable, Equatable {
    case unauthorized, httpStatus(Int), invalidResponse, invalidContentType, invalidRequest(String), redirectRejected
    case parser(SSEParserError), transport(String), bufferOverflow
}

struct URLSessionEventSource: EventSource, @unchecked Sendable {
    var timeout: TimeInterval = 30
    var maxLineBytes = 64 * 1024
    var maxEventBytes = 1024 * 1024
    var bufferCapacity = 4096
    var urlProtocolClasses: [AnyClass] = []

    /// The inactivity/request timeout remains bounded by `timeout`; the stream itself has
    /// no short client-imposed resource lifetime. Foundation may still apply system limits.
    static let streamResourceTimeout = TimeInterval.greatestFiniteMagnitude

    /// The stream plus an explicit cancellation path for callers that have not
    /// started consuming it yet.
    struct Subscription: @unchecked Sendable {
        let stream: AsyncThrowingStream<EventEnvelope, Error>
        private let cancelAction: @Sendable () -> Void

        init(stream: AsyncThrowingStream<EventEnvelope, Error>, cancel: @escaping @Sendable () -> Void) {
            self.stream = stream
            let cancellation = EventSubscriptionCancellation(action: cancel)
            self.cancelAction = { cancellation.cancel() }
        }

        func cancel() {
            cancelAction()
        }
    }

    func open(connection: ServiceConnection, request: HTTPRequest) async throws -> AsyncThrowingStream<EventEnvelope, Error> {
        try await openSubscription(connection: connection, request: request).stream
    }

    func openSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> Subscription {
        guard request.method == .get, request.body == nil else { throw EventSourceError.invalidRequest("events require GET without a body") }
        let (urlRequest, _) = try await HTTPRequestBuilder.makeRequest(connection: connection, request: request, timeout: timeout, accept: "text/event-stream")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = urlProtocolClasses
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = Self.streamResourceTimeout
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { session.invalidateAndCancel(); throw EventSourceError.invalidResponse }
            guard http.statusCode == 200 else { session.invalidateAndCancel(); throw http.statusCode == 401 ? EventSourceError.unauthorized : EventSourceError.httpStatus(http.statusCode) }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard contentType == "text/event-stream" else { session.invalidateAndCancel(); throw EventSourceError.invalidContentType }

            let box = EventTaskBox()
            let stream = AsyncThrowingStream<EventEnvelope, Error>(bufferingPolicy: .bufferingOldest(bufferCapacity)) { continuation in
                continuation.onTermination = { @Sendable _ in box.cancel() }
                box.install(Task {
                    var parser = SSEParser(maxLineBytes: maxLineBytes, maxEventBytes: maxEventBytes)
                    do {
                        for try await byte in bytes {
                            for event in try parser.append(byte) {
                                if case .dropped = continuation.yield(event) { throw EventSourceError.bufferOverflow }
                            }
                        }
                        for event in try parser.finish() {
                            if case .dropped = continuation.yield(event) { throw EventSourceError.bufferOverflow }
                        }
                        continuation.finish()
                    } catch is CancellationError { continuation.finish() }
                    catch let error as SSEParserError { continuation.finish(throwing: EventSourceError.parser(error)) }
                    catch let error as EventSourceError { continuation.finish(throwing: error) }
                    catch { continuation.finish(throwing: EventSourceError.transport("stream failed")) }
                    session.invalidateAndCancel()
                })
            }
            return Subscription(stream: stream) {
                box.cancel()
                session.invalidateAndCancel()
            }
        } catch is CancellationError { session.invalidateAndCancel(); throw CancellationError() }
        catch let error as URLError where error.code == .cancelled {
            session.invalidateAndCancel()
            if Task.isCancelled { throw CancellationError() }
            throw EventSourceError.redirectRejected
        }
        catch let error as EventSourceError { session.invalidateAndCancel(); throw error }
        catch { session.invalidateAndCancel(); throw EventSourceError.transport("stream failed") }
    }
}

private final class EventSubscriptionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var isCanceled = false

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        lock.lock()
        guard !isCanceled else {
            lock.unlock()
            return
        }
        isCanceled = true
        lock.unlock()
        action()
    }
}

private final class EventTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
        } else {
            stored = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = stored
        lock.unlock()
        task?.cancel()
    }
}
