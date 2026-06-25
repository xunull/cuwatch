import XCTest
import Combine
@testable import CuwatchCore

/// Regression tests for the popover-deadlock bug diagnosed 2026-06-25
/// (see `docs/popover-deadlock-fix-plan.md`).
///
/// The bug: PopoverViewModel's two Combine sinks ran on whichever thread
/// fired the publisher. With three ServiceMonitors each pushing
/// `StateStore.update(...)` from cooperative-pool workers, two-or-three
/// threads concurrently mutated `pendingFlushToken` and triggered
/// `DispatchScheduledWork.deinit` in the middle of `@Published`
/// lock-holding. Sample showed two cooperative workers stuck at
/// `objc_class::realizeIfNeeded → __ulock_wait2`.
///
/// The fix: `.receive(on: DispatchQueue.main)` on both sinks.
///
/// These tests MUST inject `DispatchQueueMainScheduler()` (NOT the
/// test-default `ImmediateMainScheduler()`, which runs work synchronously
/// on the calling thread and would mask the race).
@MainActor
final class PopoverViewModelConcurrencyTests: XCTestCase {

    private func snapshot(_ service: ServiceID, used: Double, at: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            service: service, readAt: at,
            window: .sessionWindow5h,
            usedFraction: used,
            resetAt: at.addingTimeInterval(3600)
        )
    }

    /// The core regression: fire `StateStore.update` and `publish` from
    /// many concurrent background queues. Without `.receive(on:)`, this
    /// reproduces the deadlock symptom (test never drains). With the fix,
    /// all writes funnel through main and the test completes within the
    /// hard cap.
    ///
    /// Hard 5s cap: a successful run on the patched code drains in <1s
    /// on a 2026-era Mac. Anything over 5s = deadlock.
    func testConcurrentEnqueueDoesNotDeadlock() {
        let store = StateStore()
        let vm = PopoverViewModel(
            stateStore: store,
            coalesceDebounce: 0.01,
            reduceMotion: false,
            scheduler: DispatchQueueMainScheduler()  // critical: real async hop
        )

        let drainExpectation = expectation(description: "all writes drained")
        let writerCount = 4
        let writesPerThread = 250
        let endTime = Date().addingTimeInterval(0.5)
        let writerGroup = DispatchGroup()

        for w in 0..<writerCount {
            writerGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let service: ServiceID = [.claude, .codex, .minimax][w % 3]
                var written = 0
                while written < writesPerThread && Date() < endTime {
                    let frac = Double((written + w) % 100) / 100.0
                    store.publish(snapshot: self.snapshot(service, used: frac))
                    store.update(monitorState: .active(lastSuccessAt: Date()), for: service)
                    written += 1
                }
                writerGroup.leave()
            }
        }

        writerGroup.notify(queue: .main) {
            // After all writers finish, give the coalescer one debounce window
            // to flush its last batch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                drainExpectation.fulfill()
            }
        }

        // 5-second hard cap. On the unpatched code this expectation never fulfills.
        wait(for: [drainExpectation], timeout: 5.0)

        // After drain, VM state should reflect SOME final write — we don't
        // care which (last-writer-wins by mtime is fine), only that the VM
        // is in a consistent published state.
        XCTAssertNotNil(vm.snapshots[.claude] ?? vm.snapshots[.codex] ?? vm.snapshots[.minimax],
                        "VM should hold at least one final snapshot after drain")
    }

    /// Single-threaded sanity check: prove that a snapshot published from a
    /// BACKGROUND queue still ends up on the VM (i.e. the main-hop didn't
    /// drop the event).
    func testSinglePublishFromBackgroundQueueReachesVMOnMain() {
        let store = StateStore()
        let vm = PopoverViewModel(
            stateStore: store,
            coalesceDebounce: 0.05,
            reduceMotion: false,
            scheduler: DispatchQueueMainScheduler()
        )

        let observed = expectation(description: "snapshot reached VM")
        var cancellable: AnyCancellable? = nil
        cancellable = vm.$snapshots.dropFirst().sink { newSnapshots in
            if newSnapshots[.claude]?.usedFraction == 0.42 {
                // Verify we're on main when the VM observes — proves the hop happened.
                XCTAssertTrue(Thread.isMainThread,
                              "VM's @Published update must arrive on main thread")
                observed.fulfill()
                cancellable?.cancel()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            store.publish(snapshot: self.snapshot(.claude, used: 0.42))
        }

        wait(for: [observed], timeout: 2.0)
    }
}
