import XCTest
@testable import CuwatchCore

final class BaseServiceMonitorTests: XCTestCase {

    // MARK: - Helpers

    private struct StubError: Error {}

    /// Make a closure-based reader that returns `result` on every poll.
    private func successReader(
        snapshot: UsageSnapshot? = nil,
        unconfigured: UnconfiguredReason? = nil
    ) -> ClosureReader<Int> {
        ClosureReader<Int>(
            poll: { _ in 0 },
            toSnapshot: { _, _ in snapshot },
            toUnconfigured: { _ in unconfigured },
            toFailureReason: { _ in .networkError }
        )
    }

    /// Counter-backed reader: increments and returns count each poll, fails on
    /// specific calls.
    private final class CountingReader: PollOutcomeProducing, @unchecked Sendable {
        typealias Outcome = Int
        var calls: Int = 0
        var failingCalls: Set<Int> = []
        var snapshots: [Int: UsageSnapshot] = [:]

        func pollOnce(now: Date) async throws -> Int {
            calls += 1
            if failingCalls.contains(calls) {
                throw StubError()
            }
            return calls
        }
        func makeSnapshot(from outcome: Int, now: Date) -> UsageSnapshot? {
            snapshots[outcome]
        }
        func unconfiguredReason(from outcome: Int) -> UnconfiguredReason? { nil }
        func failureReason(from error: Error) -> MonitorFailureReason { .networkError }
    }

    private func snapshot(_ service: ServiceID, _ frac: Double) -> UsageSnapshot {
        UsageSnapshot(
            service: service,
            readAt: Date(),
            window: .sessionWindow5h,
            usedFraction: frac,
            resetAt: nil
        )
    }

    /// Yield the cooperative thread repeatedly until `condition()` is true or
    /// `maxYields` is exceeded. The Monitor wraps async polls in a fresh Task
    /// so we need to spin a bit to let the runtime schedule it.
    private func waitFor(_ condition: () -> Bool, maxYields: Int = 200) async {
        for _ in 0..<maxYields {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Tests

    func testFirstPollSuccessTransitionsToActive() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = successReader(snapshot: snapshot(.claude, 0.7))
        let monitor = BaseServiceMonitor<ClosureReader<Int>>(
            serviceID: .claude,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        // After start, state should be active + snapshot published.
        if case .active = store.monitorStates[.claude] {
            // ok
        } else {
            XCTFail("expected active state, got \(store.monitorStates[.claude] ?? .idle)")
        }
        XCTAssertEqual(store.snapshots[.claude]?.usedFraction, 0.7)
        XCTAssertEqual(scheduler.pendingCount, 1, "should have scheduled the next poll")
    }

    func testUnconfiguredOutcomeSurfacesAndStopsRescheduling() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = successReader(unconfigured: .minimaxTokenMissing)
        let monitor = BaseServiceMonitor<ClosureReader<Int>>(
            serviceID: .minimax,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        if case .unconfigured(let reason) = store.monitorStates[.minimax] {
            XCTAssertEqual(reason, .minimaxTokenMissing)
        } else {
            XCTFail("expected unconfigured state")
        }
        XCTAssertEqual(scheduler.pendingCount, 0, "unconfigured monitors do not self-reschedule")
        XCTAssertNil(store.snapshots[.minimax])
    }

    func testFailureTransitionsToBackingOffAndIncrementsAttempt() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = CountingReader()
        reader.failingCalls = [1, 2, 3]  // first three polls fail
        let monitor = BaseServiceMonitor<CountingReader>(
            serviceID: .codex,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        if case .backingOff(_, let nextRetry, let attempt) = store.monitorStates[.codex] {
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(nextRetry, 30) // first backoff entry
        } else {
            XCTFail("expected backingOff after first failure")
        }

        scheduler.advance(by: 30) // wait, retry
        await waitFor {
            if case .backingOff(_, _, let attempt) = store.monitorStates[.codex] {
                return attempt >= 2
            }
            return false
        }
        if case .backingOff(_, let nextRetry2, let attempt2) = store.monitorStates[.codex] {
            XCTAssertEqual(attempt2, 2)
            XCTAssertEqual(nextRetry2, 60) // second backoff entry
        } else {
            XCTFail("expected backingOff state after second failure")
        }
    }

    func testFailureThenSuccessResetsBackoff() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = CountingReader()
        reader.failingCalls = [1]
        reader.snapshots[2] = snapshot(.claude, 0.5)
        let monitor = BaseServiceMonitor<CountingReader>(
            serviceID: .claude,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        if case .backingOff = store.monitorStates[.claude] { } else { XCTFail("expected backingOff") }

        scheduler.advance(by: 30)
        await waitFor {
            if case .active = store.monitorStates[.claude] { return true }
            return false
        }
        if case .active = store.monitorStates[.claude] {
            // ok — second poll succeeds, attempt counter resets
        } else {
            XCTFail("expected active after recovery")
        }
        XCTAssertEqual(store.snapshots[.claude]?.usedFraction, 0.5)
    }

    func testStopHaltsTimerAndSetsIdle() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = successReader(snapshot: snapshot(.minimax, 0.4))
        let monitor = BaseServiceMonitor<ClosureReader<Int>>(
            serviceID: .minimax,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        XCTAssertEqual(scheduler.pendingCount, 1)

        await monitor.stop()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(store.monitorStates[.minimax], .idle)
    }

    func testPollNowSkipsScheduledWait() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = CountingReader()
        let monitor = BaseServiceMonitor<CountingReader>(
            serviceID: .codex,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        XCTAssertEqual(reader.calls, 1)
        await monitor.pollNow()
        XCTAssertEqual(reader.calls, 2, "pollNow should perform an immediate extra poll")
    }

    func testDoubleStartIsIdempotent() async {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let reader = CountingReader()
        let monitor = BaseServiceMonitor<CountingReader>(
            serviceID: .claude,
            store: store,
            reader: reader,
            interval: 30,
            scheduler: scheduler
        )
        await monitor.start()
        await monitor.start()
        XCTAssertEqual(reader.calls, 1, "second start should be ignored")
    }
}
