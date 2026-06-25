import Foundation
#if canImport(Combine)
import Combine
#endif

/// View-side state for the popover and menu bar dial.
///
/// Why a separate VM instead of binding the views straight to `StateStore`?
/// The three `ServiceMonitor` instances poll on their own schedules, so updates
/// to `StateStore.snapshots` arrive at slightly different times even on the
/// same poll tick. Driving SwiftUI updates straight off that fragments the
/// "instrument settles in one motion" feel that the wedge depends on.
///
/// Per /plan-eng-review D8 + outside voice #5: coalesce all snapshot/state
/// changes that arrive within a `coalesceDebounce` window (default 500ms) into
/// a single animation tick. Reduce Motion bypasses the debounce entirely.
///
/// Pure value-type publication contract: the VM never mutates `StateStore`,
/// it only re-publishes derived view state.
///
/// **Thread safety**: `@MainActor` since 2026-06-25 (plan #2). All
/// state mutation runs on the main thread by type-system enforcement.
/// The `.receive(on: DispatchQueue.main)` calls inside `init` are retained
/// as defense in depth — if a future PR mistakenly removes `@MainActor`,
/// the runtime hop still serializes mutation. Cost is zero when already
/// on main (the hop is a no-op).
@MainActor
public final class PopoverViewModel: ObservableObject {

    // MARK: - Published view state

    /// Snapshot map currently shown by the UI. Lags `StateStore.snapshots` by ≤
    /// `coalesceDebounce` so multi-service updates land as one frame.
    @Published public private(set) var snapshots: [ServiceID: UsageSnapshot] = [:]

    @Published public private(set) var monitorStates: [ServiceID: MonitorState] = [
        .claude: .idle,
        .codex: .idle,
        .minimax: .idle,
    ]

    /// Service whose state drives the menu bar dial + popover header.
    @Published public private(set) var mainService: ServiceID? = nil

    @Published public private(set) var dialColorState: DialColorState = .neutralGrey

    /// Derived: which presentation the popover should render. Recomputed on
    /// every flush.
    @Published public private(set) var presentation: PopoverPresentation = .normalDashboard

    // MARK: - Config

    public let coalesceDebounce: TimeInterval
    public var reduceMotion: Bool

    // MARK: - Internals

    private let stateStore: StateStore
    private var cancellables = Set<AnyCancellable>()
    private let scheduler: SchedulerProvider
    private var pendingFlushToken: ScheduledWork? = nil
    private var pendingSnapshots: [ServiceID: UsageSnapshot] = [:]
    private var pendingMonitorStates: [ServiceID: MonitorState] = [:]
    private var hasPendingChanges = false

    // MARK: - Init

    public init(
        stateStore: StateStore,
        coalesceDebounce: TimeInterval = Tokens.Motion.coalesceDebounce,
        reduceMotion: Bool = false,
        scheduler: SchedulerProvider = ImmediateMainScheduler()
    ) {
        self.stateStore = stateStore
        self.coalesceDebounce = coalesceDebounce
        self.reduceMotion = reduceMotion
        self.scheduler = scheduler

        // Seed initial state.
        self.snapshots = stateStore.snapshots
        self.monitorStates = stateStore.monitorStates
        self.mainService = stateStore.mainService
        self.dialColorState = stateStore.dialColorState
        self.presentation = PopoverPresentation.resolve(
            monitorStates: stateStore.monitorStates,
            snapshots: stateStore.snapshots
        )

        // Subscribe to upstream changes.
        //
        // `.receive(on: DispatchQueue.main)` is load-bearing: the three
        // ServiceMonitors push @Published updates from cooperative-pool
        // workers (see BaseServiceMonitor.scheduleNext closures). Without
        // the hop, enqueue*/schedulePendingFlush runs on whichever cooperative
        // worker fired the publisher, and `pendingFlushToken` (a plain
        // ScheduledWork? stored prop) gets concurrently mutated by 2-3
        // monitors. The resulting deinit of the old ScheduledWork on multiple
        // threads has been observed to deadlock against Combine's internal
        // unfair_lock + ObjC realizeIfNeeded (see docs/popover-deadlock-fix-plan.md).
        //
        // Even after PopoverViewModel becomes @MainActor (see plan #2), keep
        // the explicit hop as defense in depth — a publisher already on main
        // skips the hop, so runtime cost is zero.
        stateStore.$snapshots
            .dropFirst()       // already seeded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] new in
                self?.enqueueSnapshotChange(new)
            }
            .store(in: &cancellables)
        stateStore.$monitorStates
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] new in
                self?.enqueueMonitorStateChange(new)
            }
            .store(in: &cancellables)
    }

    // MARK: - Test-facing flush hook

    /// Force any pending coalesced updates to publish immediately. Tests use this
    /// to drive deterministic assertions without waiting for a real timer.
    public func flushPendingForTesting() {
        flushNow()
    }

    // MARK: - Coalescer

    private func enqueueSnapshotChange(_ new: [ServiceID: UsageSnapshot]) {
        pendingSnapshots = new
        hasPendingChanges = true
        if reduceMotion {
            flushNow()
        } else {
            schedulePendingFlush()
        }
    }

    private func enqueueMonitorStateChange(_ new: [ServiceID: MonitorState]) {
        pendingMonitorStates = new
        hasPendingChanges = true
        if reduceMotion {
            flushNow()
        } else {
            schedulePendingFlush()
        }
    }

    private func schedulePendingFlush() {
        // Cancel any in-flight scheduled flush. The window restarts on every change
        // so a burst of updates all collapse into one publish.
        pendingFlushToken?.cancel()
        pendingFlushToken = scheduler.schedule(after: coalesceDebounce) { [weak self] in
            self?.flushNow()
        }
    }

    private func flushNow() {
        pendingFlushToken?.cancel()
        pendingFlushToken = nil
        guard hasPendingChanges else { return }
        hasPendingChanges = false

        // Publish the latest seen values (StateStore is the source of truth).
        let nextSnapshots = pendingSnapshots.isEmpty ? stateStore.snapshots : pendingSnapshots
        let nextMonitorStates = pendingMonitorStates.isEmpty ? stateStore.monitorStates : pendingMonitorStates

        snapshots = nextSnapshots
        monitorStates = nextMonitorStates
        mainService = stateStore.mainService
        dialColorState = stateStore.dialColorState
        presentation = PopoverPresentation.resolve(
            monitorStates: nextMonitorStates,
            snapshots: nextSnapshots
        )

        pendingSnapshots.removeAll(keepingCapacity: true)
        pendingMonitorStates.removeAll(keepingCapacity: true)
    }
}

// MARK: - Scheduler abstraction (so we don't take a dependency on real time in tests)

/// A pluggable abstraction for "do this after a delay on the main queue".
/// Production uses `DispatchQueueMainScheduler` which wraps `DispatchQueue.main`.
/// Tests use `ManualScheduler` to advance virtual time deterministically.
public protocol SchedulerProvider {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
}

/// Handle on a scheduled piece of work — call `cancel()` to prevent it firing.
public protocol ScheduledWork {
    func cancel()
}

/// Production implementation: dispatch to main queue after a delay.
public final class DispatchQueueMainScheduler: SchedulerProvider {
    public init() {}
    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchScheduledWork(item: item)
    }
}

private final class DispatchScheduledWork: ScheduledWork {
    let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

/// Synchronous fallback — invokes work immediately. Useful as a default when the
/// real production scheduler isn't injected (e.g. in unit tests of unrelated code).
public final class ImmediateMainScheduler: SchedulerProvider {
    public init() {}
    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        work()
        return NoOpScheduledWork()
    }
}

private final class NoOpScheduledWork: ScheduledWork {
    func cancel() {}
}

/// Manually-driven scheduler for tests: nothing fires until `advance()` is called.
public final class ManualScheduler: SchedulerProvider {

    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let entry = Entry(delay: delay, work: work)
        pending.append(entry)
        return Handle(entry: entry, scheduler: self)
    }

    /// Fire any work whose delay is ≤ the time advance, in scheduled order.
    public func advance(by delta: TimeInterval) {
        // Reduce remaining time on each entry; fire (and discard) any that have
        // expired. We do this in two passes so cancellations during fire don't
        // perturb the iteration.
        for entry in pending {
            entry.remaining -= delta
        }
        let due = pending.filter { $0.remaining <= 0 && !$0.cancelled }
        pending.removeAll { $0.remaining <= 0 }
        for entry in due {
            entry.work()
        }
    }

    /// Run every scheduled item now regardless of remaining time. Used to assert
    /// "no work was scheduled at all" by counting `pendingCount` before calling.
    public func drainAll() {
        let due = pending.filter { !$0.cancelled }
        pending.removeAll()
        for entry in due { entry.work() }
    }

    public var pendingCount: Int { pending.filter { !$0.cancelled }.count }

    // MARK: -

    private final class Entry {
        var remaining: TimeInterval
        let work: () -> Void
        var cancelled = false
        init(delay: TimeInterval, work: @escaping () -> Void) {
            self.remaining = delay
            self.work = work
        }
    }

    private final class Handle: ScheduledWork {
        let entry: Entry
        weak var scheduler: ManualScheduler?
        init(entry: Entry, scheduler: ManualScheduler) {
            self.entry = entry
            self.scheduler = scheduler
        }
        func cancel() {
            entry.cancelled = true
            scheduler?.pending.removeAll { $0 === entry }
        }
    }

    private var pending: [Entry] = []
}
