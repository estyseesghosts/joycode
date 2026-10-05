import Foundation

/// One application-level signal derived from the single `/api/event`
/// subscription of a connection generation.
///
/// Pinned OpenCode v2.0.20 (`packages/server/src/handlers/event.ts`,
/// `event-feed.ts`): the server registers the subscriber's queue *before* it
/// emits the bare `server.connected` frame (`data: {}`), so after that marker
/// every later publication is queued for this subscriber. Events before it are
/// not replayed. The per-subscriber queue is a 4096-entry dropping queue; an
/// overflow fails the stream, so `.failed` means events may have been lost,
/// not merely that the connection ended. The marker carries no backend
/// generation, version or snapshot watermark, so it is a readiness signal
/// only. Delivery is live-only: no replay, no exactly-once, no total order.
enum ConnectionEventSignal: Sendable {
    /// `server.connected` was received for `generation`.
    case connected(generation: UInt64)
    /// Any other decoded event, in arrival order within one subscription.
    case event(generation: UInt64, envelope: EventEnvelope)
    /// The subscription ended or failed. Events may have been missed.
    case failed(generation: UInt64)

    var generation: UInt64 {
        switch self {
        case .connected(let generation), .event(let generation, _), .failed(let generation):
            return generation
        }
    }
}

/// Current stream phase for one generation, replayed to late observers so
/// composition order cannot hide readiness or failure.
enum ConnectionEventStreamPhase: Equatable, Sendable {
    case idle
    case connecting(generation: UInt64)
    case ready(generation: UInt64)
    case failed(generation: UInt64)
}

/// Fans the one network subscription out to application observers on the
/// main actor. Observers are plain closures owned by composition-bound stores;
/// no view ever subscribes. Delivery is synchronous and in arrival order.
@MainActor
final class ConnectionEventFanout {
    typealias Handler = @MainActor (ConnectionEventSignal) -> Void

    private(set) var phase: ConnectionEventStreamPhase = .idle
    private var observers: [(id: UInt64, handler: Handler)] = []
    private var nextObserverID: UInt64 = 0

    /// Registers an observer. The current ready/failed phase (if any) is
    /// replayed immediately so late registration cannot miss readiness.
    /// The returned observation unregisters on release or `cancel()`.
    func addObserver(_ handler: @escaping Handler) -> ConnectionEventObservation {
        nextObserverID &+= 1
        let id = nextObserverID
        observers.append((id, handler))
        switch phase {
        case .ready(let generation): handler(.connected(generation: generation))
        case .failed(let generation): handler(.failed(generation: generation))
        case .idle, .connecting: break
        }
        return ConnectionEventObservation { [weak self] in self?.removeObserver(id) }
    }

    /// Starts a new subscription phase. Not an event: observers learn of
    /// generation replacement from their own connection context.
    func reset(generation: UInt64?) {
        phase = generation.map { .connecting(generation: $0) } ?? .idle
    }

    /// Records the signal's phase and notifies a stable copy of the observers.
    /// Signals for a generation other than the current phase generation are
    /// dropped so a late old stream cannot move readiness.
    func deliver(_ signal: ConnectionEventSignal) {
        switch (signal, phase) {
        case (.connected(let generation), _):
            guard Self.isCurrent(generation, phase) else { return }
            phase = .ready(generation: generation)
        case (.failed(let generation), _):
            guard Self.isCurrent(generation, phase) else { return }
            phase = .failed(generation: generation)
        case (.event(let generation, _), _):
            guard Self.isCurrent(generation, phase) else { return }
        }
        for observer in observers { observer.handler(signal) }
    }

    private static func isCurrent(_ generation: UInt64, _ phase: ConnectionEventStreamPhase) -> Bool {
        switch phase {
        case .idle: return false
        case .connecting(let current), .ready(let current), .failed(let current): return current == generation
        }
    }

    fileprivate func removeObserver(_ id: UInt64) {
        observers.removeAll { $0.id == id }
    }

    var observerCount: Int { observers.count }
}

/// Unregisters its observer on `cancel()` or release. Stores keep it so
/// correctness never depends on view lifetime.
final class ConnectionEventObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@MainActor @Sendable () -> Void)?

    init(_ cancel: @escaping @MainActor @Sendable () -> Void) {
        action = cancel
    }

    func cancel() {
        lock.lock()
        let pending = action
        action = nil
        lock.unlock()
        guard let pending else { return }
        Task { @MainActor in pending() }
    }

    deinit { cancel() }
}
