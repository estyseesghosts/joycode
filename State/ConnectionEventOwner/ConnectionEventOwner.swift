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

struct ConnectionEventDiagnostics: Equatable, Sendable {
    var count: Int
    var latestType: String?
    var failed: Bool
}

@MainActor
final class ConnectionEventOwner: ObservableObject {
    /// Single coalesced visible diagnostic publication. Per-event receipt
    /// updates internal pending state and delivers fanout immediately; this
    /// snapshot is flushed at most once per burst so a storm does not
    /// publish once per event.
    @Published private(set) var diagnostics = ConnectionEventDiagnostics(count: 0, latestType: nil, failed: false)

    /// Backward-compatible value reads over the coalesced visible snapshot.
    /// These are plain computed properties (no per-key publisher); observe
    /// `$diagnostics` for reactive updates.
    var eventCount: Int { diagnostics.count }
    var latestEventType: String? { diagnostics.latestType }
    var subscriptionFailed: Bool { diagnostics.failed }

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
    /// Exact internal accounting; the visible `diagnostics` snapshot is a
    /// coalesced flush of this pending state.
    private var pendingCount = 0
    private var pendingLatestType: String?
    private var pendingFailed = false
    private var flushTask: Task<Void, Never>?
    private var flushGeneration: UInt64?
    /// Visible-diagnostic coalescing window. Fanout delivery is never gated
    /// on this delay; it only bounds how often `$diagnostics` publishes
    /// during a burst. Failure and generation transitions publish
    /// synchronously and cancel any pending flush.
    private static let diagnosticsFlushDelay = Duration.milliseconds(20)

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
        flushTask?.cancel()
    }

    private func contextChanged(_ context: ServiceConnectionContext?) {
        let newGeneration = context?.generation
        guard newGeneration != generation else { return }

        subscription?.cancel()
        subscription = nil
        task?.cancel()
        task = nil
        generation = newGeneration
        cancelPendingFlush()
        pendingCount = 0
        pendingLatestType = nil
        pendingFailed = false
        publishDiagnosticsNow()
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
                    self.noteEvent(event, generation: context.generation)
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
        pendingFailed = true
        publishDiagnosticsNow()
        releaseFinishedSubscription()
        fanout.deliver(.failed(generation: generation))
    }

    /// Records exact internal accounting, schedules at most one pending
    /// visible-diagnostic flush for the burst, and delivers fanout
    /// immediately: fanout is never delayed by diagnostics.
    private func noteEvent(_ event: EventEnvelope, generation: UInt64) {
        pendingCount = min(pendingCount + 1, Self.maximumEventCount)
        pendingLatestType = Self.safeEventType(event.type)
        scheduleDiagnosticsFlush(generation: generation)
        // The generation was just verified current, so the fanout
        // carries only the live subscription's signals.
        if event.type == "server.connected" {
            fanout.deliver(.connected(generation: generation))
        } else {
            fanout.deliver(.event(generation: generation, envelope: event))
        }
    }

    /// Schedules at most one pending flush per burst, bound to the
    /// generation that scheduled it. A stale task can never publish into a
    /// new generation: context transitions cancel the pending task and the
    /// flush rechecks currency before publishing.
    private func scheduleDiagnosticsFlush(generation: UInt64) {
        guard flushTask == nil else { return }
        flushGeneration = generation
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.diagnosticsFlushDelay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.flushDiagnostics(generation: generation)
        }
    }

    private func flushDiagnostics(generation: UInt64) {
        guard generation == flushGeneration, generation == self.generation else { return }
        flushTask = nil
        flushGeneration = nil
        publishDiagnosticsNow()
    }

    private func cancelPendingFlush() {
        flushTask?.cancel()
        flushTask = nil
        flushGeneration = nil
    }

    /// Publishes the pending snapshot synchronously, cancelling any pending
    /// burst flush. Skips the assignment when nothing changed so an idle
    /// reset does not emit a redundant publication.
    private func publishDiagnosticsNow() {
        cancelPendingFlush()
        let next = ConnectionEventDiagnostics(count: pendingCount, latestType: pendingLatestType, failed: pendingFailed)
        if next != diagnostics {
            diagnostics = next
        }
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
