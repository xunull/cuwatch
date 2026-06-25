import XCTest
@testable import CuwatchCore

@MainActor
final class PopoverViewModelTests: XCTestCase {

    private func snapshot(_ service: ServiceID, used: Double, at: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            service: service, readAt: at,
            window: .sessionWindow5h,
            usedFraction: used,
            resetAt: at.addingTimeInterval(3600)
        )
    }

    /// Drain the main run loop. Required because `PopoverViewModel`'s sinks
    /// now hop through `.receive(on: DispatchQueue.main)` (added 2026-06-25 to
    /// fix the popover deadlock — see `docs/popover-deadlock-fix-plan.md`).
    /// Without draining, a `store.publish(...)` only enqueues an async block
    /// on the main queue; assertions that follow run before the block fires.
    private func pumpMain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Coalescer

    func testInitialStateMirrorsStateStore() {
        let store = StateStore()
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.publish(snapshot: snapshot(.claude, used:0.6))

        let vm = PopoverViewModel(stateStore: store, scheduler: ManualScheduler())
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction, 0.6)
        XCTAssertEqual(vm.mainService, .claude)
        XCTAssertEqual(vm.dialColorState, .brass)
    }

    func testSingleChangePublishesAfterDebounce() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: false, scheduler: scheduler
        )
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.publish(snapshot: snapshot(.claude, used:0.78))
        pumpMain()  // drain sinks so schedulePendingFlush registers work

        // Update should still be pending. Multiple coalesced changes share a
        // single pending work item — that's the whole point of debounce.
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(scheduler.pendingCount, 1)

        // Advance the manual clock.
        scheduler.advance(by: 0.6)
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0.78, accuracy: 0.001)
    }

    func testMultipleChangesWithinWindowCollapseToOnePublish() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: false, scheduler: scheduler
        )

        // Three services publish in close succession.
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .minimax)
        store.publish(snapshot: snapshot(.claude, used:0.8))
        store.publish(snapshot: snapshot(.codex, used:0.65))
        store.publish(snapshot: snapshot(.minimax, used:0.41))
        pumpMain()

        // Still pending before window elapses.
        XCTAssertTrue(vm.snapshots.isEmpty)
        // Advance: the latest pending flush is what fires.
        scheduler.advance(by: 0.6)

        XCTAssertEqual(vm.snapshots.count, 3)
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(vm.snapshots[.codex]?.usedFraction ?? 0, 0.65, accuracy: 0.001)
        XCTAssertEqual(vm.snapshots[.minimax]?.usedFraction ?? 0, 0.41, accuracy: 0.001)
        // Main service election picks highest used among published — claude
        // at 0.80 leads codex (0.65) and minimax (0.41).
        XCTAssertEqual(vm.mainService, .claude)
    }

    func testNewChangeInWindowExtendsTheWindow() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: false, scheduler: scheduler
        )

        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.publish(snapshot: snapshot(.claude, used:0.50))
        pumpMain()

        // Advance partway through the debounce window.
        scheduler.advance(by: 0.3)
        XCTAssertTrue(vm.snapshots.isEmpty, "Should not have flushed yet")

        // Another change arrives — restarts the window.
        store.publish(snapshot: snapshot(.claude, used:0.45))
        pumpMain()
        scheduler.advance(by: 0.3)
        // Still no flush because the second change reset the timer.
        XCTAssertTrue(vm.snapshots.isEmpty, "Window should have reset, not fired")

        // Now finish the full debounce window from the second change.
        scheduler.advance(by: 0.3)
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0.45, accuracy: 0.001)
    }

    func testReduceMotionFlushesImmediately() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: true, scheduler: scheduler
        )
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.publish(snapshot: snapshot(.claude, used:0.55))
        pumpMain()

        // Reduce Motion should publish without waiting on the scheduler.
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0.55, accuracy: 0.001)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testFlushPendingForTestingForcesPublish() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: false, scheduler: scheduler
        )
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        // 0.75 used → warn band (≥0.70, <0.90) → burntOrange.
        store.publish(snapshot: snapshot(.codex, used: 0.75))
        pumpMain()
        XCTAssertTrue(vm.snapshots.isEmpty)

        vm.flushPendingForTesting()
        XCTAssertEqual(vm.snapshots[.codex]?.usedFraction ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(vm.dialColorState, .burntOrange)
    }

    func testMonitorStateChangesCoalesceWithSnapshotChanges() {
        let store = StateStore()
        let scheduler = ManualScheduler()
        let vm = PopoverViewModel(
            stateStore: store, coalesceDebounce: 0.5, reduceMotion: false, scheduler: scheduler
        )

        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        // Both should be pending and a single flush should publish them together.
        store.publish(snapshot: snapshot(.claude, used:0.7))
        pumpMain()

        scheduler.advance(by: 0.6)
        if case .active = vm.monitorStates[.claude] {
            // ok
        } else {
            XCTFail("monitor state did not flush")
        }
        XCTAssertEqual(vm.snapshots[.claude]?.usedFraction ?? 0, 0.7, accuracy: 0.001)
    }
}

// MARK: - ManualScheduler self-tests

final class ManualSchedulerSelfTests: XCTestCase {

    func testWorkFiresAfterAdvance() {
        let s = ManualScheduler()
        var fired = false
        _ = s.schedule(after: 0.5) { fired = true }
        XCTAssertFalse(fired)
        s.advance(by: 0.4)
        XCTAssertFalse(fired)
        s.advance(by: 0.2)
        XCTAssertTrue(fired)
    }

    func testCancelPreventsFire() {
        let s = ManualScheduler()
        var fired = false
        let handle = s.schedule(after: 0.5) { fired = true }
        handle.cancel()
        s.advance(by: 1.0)
        XCTAssertFalse(fired)
    }

    func testDrainAllFiresEverythingRegardlessOfTime() {
        let s = ManualScheduler()
        var fireCount = 0
        _ = s.schedule(after: 1.0) { fireCount += 1 }
        _ = s.schedule(after: 100.0) { fireCount += 1 }
        s.drainAll()
        XCTAssertEqual(fireCount, 2)
        XCTAssertEqual(s.pendingCount, 0)
    }
}
