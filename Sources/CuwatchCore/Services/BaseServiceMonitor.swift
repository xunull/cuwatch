import Foundation

/// Reusable polling + backoff machinery for the three concrete service monitors.
///
/// Subclasses implement `pollOnce(now:)` to do the actual read (filesystem,
/// HTTPS, whatever); the base class handles:
/// - Scheduling the next poll on a configurable cadence
/// - Backoff on failure (per `BackoffSchedule`)
/// - State transitions into the shared `StateStore`
/// - Wake-from-sleep prompt re-polls
///
/// Polling architecture per /plan-eng-review D3: each subclass owns its own
/// `BaseServiceMonitor` instance. Failure in one service does not affect the
/// schedule of the others.
public protocol PollOutcomeProducing: AnyObject {
    associatedtype Outcome
    /// Perform a single poll. Throws on transient/permanent error.
    func pollOnce(now: Date) async throws -> Outcome
    /// Convert a successful outcome into a snapshot to publish (or nil to
    /// suppress publication this tick, e.g. spike-pending state for Codex).
    func makeSnapshot(from outcome: Outcome, now: Date) -> UsageSnapshot?
    /// Decide whether the outcome ALSO indicates an "unconfigured" state
    /// (token missing, FDA blocked, codex not installed). Returns the reason
    /// to publish, or nil to stay active.
    func unconfiguredReason(from outcome: Outcome) -> UnconfiguredReason?
    /// Convert an error into a `MonitorFailureReason` for the state store.
    func failureReason(from error: Error) -> MonitorFailureReason
}

/// Reusable polling driver. Sub-actor-state machine:
///
/// ```
///   ┌──────┐  start() ──▶ ┌────────┐  success ─▶ ┌────────┐
///   │ idle │              │polling │             │ active │ ─poll tick─▶ polling
///   └──────┘              └────────┘             └────────┘
///                            │ │                     │
///                            │ └─error─────▶ ┌───────────┐
///                            │               │ backingOff│ ─delay─▶ polling
///                            │               └───────────┘
///                            └─unconfigured──▶ ┌────────────┐
///                                              │unconfigured│ ─pollNow()─▶ polling
///                                              └────────────┘
/// ```
public final class BaseServiceMonitor<Reader: PollOutcomeProducing>: ServiceMonitor, @unchecked Sendable {

    public let serviceID: ServiceID
    public let store: StateStore
    public let reader: Reader
    public let interval: TimeInterval
    public let backoff: BackoffSchedule
    public let scheduler: SchedulerProvider
    public let clock: () -> Date

    private var scheduledWork: ScheduledWork?
    private var failureAttempt: Int = 0
    private var isRunning: Bool = false
    private let queue: DispatchQueue

    public init(
        serviceID: ServiceID,
        store: StateStore,
        reader: Reader,
        interval: TimeInterval = Tokens.Polling.defaultIntervalSeconds,
        backoff: BackoffSchedule = .default,
        scheduler: SchedulerProvider = DispatchQueueMainScheduler(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.serviceID = serviceID
        self.store = store
        self.reader = reader
        self.interval = interval
        self.backoff = backoff
        self.scheduler = scheduler
        self.clock = clock
        self.queue = DispatchQueue(label: "cuwatch.monitor.\(serviceID.rawValue)")
    }

    // MARK: - ServiceMonitor

    public func start() async {
        let shouldRun = queue.sync { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldRun else { return }
        await performPoll()
    }

    public func stop() async {
        queue.sync {
            isRunning = false
            scheduledWork?.cancel()
            scheduledWork = nil
        }
        store.update(monitorState: .idle, for: serviceID)
    }

    public func pollNow() async {
        // Cancel pending and poll immediately.
        queue.sync {
            scheduledWork?.cancel()
            scheduledWork = nil
        }
        await performPoll()
    }

    // MARK: - Core loop

    private func performPoll() async {
        let now = clock()
        do {
            let outcome = try await reader.pollOnce(now: now)
            handleSuccess(outcome: outcome, now: now)
        } catch {
            handleError(error: error)
        }
    }

    private func handleSuccess(outcome: Reader.Outcome, now: Date) {
        if let reason = reader.unconfiguredReason(from: outcome) {
            store.clearSnapshot(for: serviceID)
            store.update(monitorState: .unconfigured(reason: reason), for: serviceID)
            // Do NOT auto-reschedule. pollNow() will resume after user fixes
            // the underlying issue (added a token, granted FDA, etc).
            queue.sync { scheduledWork = nil }
            return
        }
        // Active: publish snapshot if reader produced one.
        if let snapshot = reader.makeSnapshot(from: outcome, now: now) {
            store.publish(snapshot: snapshot)
        }
        store.update(monitorState: .active(lastSuccessAt: now), for: serviceID)
        failureAttempt = 0
        scheduleNext(after: interval)
    }

    private func handleError(error: Error) {
        let reason = reader.failureReason(from: error)
        let delay = backoff.interval(forAttempt: failureAttempt)
        failureAttempt += 1
        store.update(
            monitorState: .backingOff(reason: reason, nextRetryIn: delay, attempt: failureAttempt),
            for: serviceID
        )
        scheduleNext(after: delay)
    }

    private func scheduleNext(after delay: TimeInterval) {
        // Only schedule if we should still be running.
        let shouldRun = queue.sync { isRunning }
        guard shouldRun else { return }
        let work = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            Task { await self.performPoll() }
        }
        queue.sync { scheduledWork = work }
    }
}

// MARK: - Type-erased helper

/// Lightweight wrapper over a closure so we can build a Monitor without a
/// dedicated subclass when the reader is just a simple closure (used in
/// tests and dev demo paths).
public final class ClosureReader<T>: PollOutcomeProducing {
    public typealias Outcome = T

    public let poll: @Sendable (Date) async throws -> T
    public let toSnapshot: (T, Date) -> UsageSnapshot?
    public let toUnconfigured: (T) -> UnconfiguredReason?
    public let toFailureReason: (Error) -> MonitorFailureReason

    public init(
        poll: @escaping @Sendable (Date) async throws -> T,
        toSnapshot: @escaping (T, Date) -> UsageSnapshot?,
        toUnconfigured: @escaping (T) -> UnconfiguredReason? = { _ in nil },
        toFailureReason: @escaping (Error) -> MonitorFailureReason = { _ in .networkError }
    ) {
        self.poll = poll
        self.toSnapshot = toSnapshot
        self.toUnconfigured = toUnconfigured
        self.toFailureReason = toFailureReason
    }

    public func pollOnce(now: Date) async throws -> T {
        try await poll(now)
    }

    public func makeSnapshot(from outcome: T, now: Date) -> UsageSnapshot? {
        toSnapshot(outcome, now)
    }

    public func unconfiguredReason(from outcome: T) -> UnconfiguredReason? {
        toUnconfigured(outcome)
    }

    public func failureReason(from error: Error) -> MonitorFailureReason {
        toFailureReason(error)
    }
}
