import XCTest
@testable import CuwatchCore

final class StateStoreTests: XCTestCase {

    private func snapshot(_ service: ServiceID, used: Double) -> UsageSnapshot {
        UsageSnapshot(
            service: service,
            readAt: Date(),
            window: .sessionWindow5h,
            usedFraction: used,
            resetAt: Date().addingTimeInterval(3600)
        )
    }

    func testInitialState() {
        let store = StateStore()
        XCTAssertNil(store.mainService)
        XCTAssertEqual(store.dialColorState, .neutralGrey)
        XCTAssertTrue(store.snapshots.isEmpty)
    }

    func testMainServiceElectionPicksHighestUsed() {
        let store = StateStore()
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .minimax)
        store.publish(snapshot: snapshot(.claude, used: 0.22))
        store.publish(snapshot: snapshot(.codex, used: 0.80))     // highest used
        store.publish(snapshot: snapshot(.minimax, used: 0.59))
        XCTAssertEqual(store.mainService, .codex)
    }

    func testMainServiceElectionExcludesUnconfigured() {
        let store = StateStore()
        store.update(monitorState: .unconfigured(reason: .missingFullDiskAccess), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .minimax)
        // Claude has a hot snapshot but is unconfigured → must not drive the dial.
        store.publish(snapshot: snapshot(.claude, used: 0.95))
        store.publish(snapshot: snapshot(.codex, used: 0.35))
        store.publish(snapshot: snapshot(.minimax, used: 0.59)) // highest among eligible
        XCTAssertEqual(store.mainService, .minimax)
    }

    func testMainServiceElectionIncludesBackingOff() {
        // backingOff still has a recent snapshot — keep counting it.
        let store = StateStore()
        store.update(monitorState: .backingOff(reason: .networkError, nextRetryIn: 60, attempt: 1), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.publish(snapshot: snapshot(.claude, used: 0.90))
        store.publish(snapshot: snapshot(.codex, used: 0.50))
        XCTAssertEqual(store.mainService, .claude)
    }

    func testMainServiceElectionTieBreakIsStable() {
        let store = StateStore()
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.publish(snapshot: snapshot(.claude, used: 0.50))
        store.publish(snapshot: snapshot(.codex, used: 0.50))
        // ServiceID order: claude < codex → claude wins ties.
        XCTAssertEqual(store.mainService, .claude)
    }

    func testDialColorStateMaps() {
        // Vendor-aligned ladder: green <70% used, yellow 70-90%, red ≥90%.
        let store = StateStore()
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)

        store.publish(snapshot: snapshot(.claude, used: 0.15))
        XCTAssertEqual(store.dialColorState, .brass)

        store.publish(snapshot: snapshot(.claude, used: 0.70))
        XCTAssertEqual(store.dialColorState, .burntOrange)

        store.publish(snapshot: snapshot(.claude, used: 0.95))
        XCTAssertEqual(store.dialColorState, .oxidizedRed)
    }

    func testClearSnapshotRemovesServiceFromElection() {
        let store = StateStore()
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .claude)
        store.update(monitorState: .active(lastSuccessAt: Date()), for: .codex)
        store.publish(snapshot: snapshot(.claude, used: 0.80))   // highest used initially
        store.publish(snapshot: snapshot(.codex, used: 0.20))
        XCTAssertEqual(store.mainService, .claude)
        store.clearSnapshot(for: .claude)
        XCTAssertEqual(store.mainService, .codex)
    }

    func testIdleServicesAreNeverMain() {
        let store = StateStore()
        // Both have snapshots but neither monitor is active → no main service.
        store.publish(snapshot: snapshot(.claude, used: 0.90))
        store.publish(snapshot: snapshot(.minimax, used: 0.95))
        XCTAssertNil(store.mainService)
        XCTAssertEqual(store.dialColorState, .neutralGrey)
    }
}
