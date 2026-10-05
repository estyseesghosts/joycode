import Foundation
import Combine

protocol ConnectionEventSubscriptionSource: Sendable {
    func openConnectionEventSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> ConnectionEventSubscription
}

struct ConnectionEventSubscription: @unchecked Sendable {
    let stream: AsyncThrowingStream<EventEnvelope, Error>
    private let cancellation: @Sendable () -> Void

    init(stream: AsyncThrowingStream<EventEnvelope, Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.stream = stream
        self.cancellation = cancel
    }

    func cancel() { cancellation() }
}

extension URLSessionEventSource: ConnectionEventSubscriptionSource {
    func openConnectionEventSubscription(connection: ServiceConnection, request: HTTPRequest) async throws -> ConnectionEventSubscription {
        let subscription = try await openSubscription(connection: connection, request: request)
        return ConnectionEventSubscription(stream: subscription.stream, cancel: subscription.cancel)
    }
}

@MainActor
final class ConnectionEventOwner: ObservableObject {
    @Published private(set) var eventCount = 0
    @Published private(set) var latestEventType: String?
    @Published private(set) var subscriptionFailed = false

    /// Application fanout of the single network subscription. Observers are
    /// stores bound by composition; the owner still opens exactly one stream
    /// per connection generation.
    let fanout = ConnectionEventFanout()

    private let connectionOwner: ServiceConnectionOwner
    private let source: any ConnectionEventSubscriptionSource
    private var contextCancellable: AnyCancellable?
    private var task: Task<Void, Never>?
    private var subscription: ConnectionEventSubscription?
    private var generation: UInt64?
    private static let maximumEventCount = 1_000_000

    init(
        connectionOwner: ServiceConnectionOwner,
        source: any ConnectionEventSubscriptionSource = URLSessionEventSource()
    ) {
        self.connectionOwner = connectionOwner
        self.source = source
        contextCancellable = connectionOwner.$currentContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] context in self?.contextChanged(context) }
        contextChanged(connectionOwner.currentContext)
    }

    deinit {
        task?.cancel()
        subscription?.cancel()
    }

    private func contextChanged(_ context: ServiceConnectionContext?) {
        let newGeneration = context?.generation
        guard newGeneration != generation else { return }

        subscription?.cancel()
        subscription = nil
        task?.cancel()
        task = nil
        generation = newGeneration
        eventCount = 0
        latestEventType = nil
        subscriptionFailed = false
        fanout.reset(generation: newGeneration)

        guard let context else { return }
        let source = self.source
        let connectionOwner = self.connectionOwner
        task = Task { [weak self] in
            guard !Task.isCancelled,
                  connectionOwner.currentContext?.generation == context.generation else { return }
            do {
                let opened = try await source.openConnectionEventSubscription(
                    connection: context.connection,
                    request: HTTPRequest(method: .get, relativePath: "/api/event")
                )
                guard !Task.isCancelled else { opened.cancel(); return }
                guard self?.isCurrent(context.generation) == true else { opened.cancel(); return }
                self?.subscription = opened
                for try await event in opened.stream {
                    guard !Task.isCancelled else { return }
                    guard let self, self.isCurrent(context.generation) else { return }
                    self.eventCount = min(self.eventCount + 1, Self.maximumEventCount)
                    self.latestEventType = Self.safeEventType(event.type)
                    // The generation was just verified current, so the fanout
                    // carries only the live subscription's signals.
                    if event.type == "server.connected" {
                        self.fanout.deliver(.connected(generation: context.generation))
                    } else {
                        self.fanout.deliver(.event(generation: context.generation, envelope: event))
                    }
                }
                guard !Task.isCancelled, let self, self.isCurrent(context.generation) else { return }
                self.streamEnded(generation: context.generation)
            } catch is CancellationError {
                guard !Task.isCancelled, let self, self.isCurrent(context.generation) else { return }
                self.streamEnded(generation: context.generation)
            } catch {
                guard !Task.isCancelled, let self, self.isCurrent(context.generation) else { return }
                self.streamEnded(generation: context.generation)
            }
        }
    }

    private func isCurrent(_ contextGeneration: UInt64) -> Bool {
        generation == contextGeneration && connectionOwner.currentContext?.generation == contextGeneration
    }

    /// A current subscription that ended or failed. Live-only delivery means
    /// events may have been missed, so observers are told rather than left to
    /// infer continuity from silence. Recovery (R13) is not implemented here.
    private func streamEnded(generation: UInt64) {
        subscriptionFailed = true
        releaseFinishedSubscription()
        fanout.deliver(.failed(generation: generation))
    }

    private func releaseFinishedSubscription() {
        subscription?.cancel()
        subscription = nil
    }

    private static func safeEventType(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39) ||
            ($0.value >= 0x41 && $0.value <= 0x5a) ||
            ($0.value >= 0x61 && $0.value <= 0x7a) ||
            $0 == "." || $0 == "_" || $0 == "-"
        }), !value.isEmpty, value.count <= 80 else { return nil }
        return value
    }
}
