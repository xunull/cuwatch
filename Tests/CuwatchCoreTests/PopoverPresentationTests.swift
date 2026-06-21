import XCTest
@testable import CuwatchCore

final class PopoverPresentationTests: XCTestCase {

    private func snapshot(_ service: ServiceID, _ frac: Double) -> UsageSnapshot {
        UsageSnapshot(
            service: service,
            readAt: Date(),
            window: .sessionWindow5h,
            usedFraction: frac,
            resetAt: Date().addingTimeInterval(3600)
        )
    }

    // MARK: - State A — onboardingAllServices

    func testAllUnconfiguredMapsToOnboarding() {
        let states: [ServiceID: MonitorState] = [
            .claude: .unconfigured(reason: .missingFullDiskAccess),
            .codex: .unconfigured(reason: .codexNotInstalled),
            .minimax: .unconfigured(reason: .minimaxTokenMissing),
        ]
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: [:])
        if case .onboardingAllServices = result {
            // ok
        } else {
            XCTFail("expected onboardingAllServices, got \(result)")
        }
    }

    // MARK: - State B — claudeFDABlocked

    func testClaudeFDABlockedRoutesToDedicatedCard() {
        let states: [ServiceID: MonitorState] = [
            .claude: .unconfigured(reason: .missingFullDiskAccess),
            .codex: .active(lastSuccessAt: Date()),
            .minimax: .active(lastSuccessAt: Date()),
        ]
        let snapshots: [ServiceID: UsageSnapshot] = [
            .codex: snapshot(.codex, 0.7),
            .minimax: snapshot(.minimax, 0.5),
        ]
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: snapshots)
        if case .claudeFDABlocked(let others) = result {
            XCTAssertEqual(others.count, 2)
            XCTAssertNotNil(others[.codex])
            XCTAssertNotNil(others[.minimax])
        } else {
            XCTFail("expected claudeFDABlocked, got \(result)")
        }
    }

    // MARK: - State C — partiallyConfigured

    func testPartialConfigurationRoutesToPartiallyConfigured() {
        let states: [ServiceID: MonitorState] = [
            .claude: .active(lastSuccessAt: Date()),
            .codex: .unconfigured(reason: .codexNotInstalled),
            .minimax: .active(lastSuccessAt: Date()),
        ]
        let snapshots: [ServiceID: UsageSnapshot] = [
            .claude: snapshot(.claude, 0.8),
            .minimax: snapshot(.minimax, 0.4),
        ]
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: snapshots)
        if case .partiallyConfigured(let states) = result {
            XCTAssertEqual(states.count, 3)
        } else {
            XCTFail("expected partiallyConfigured, got \(result)")
        }
    }

    // MARK: - State D — allConfiguredWithDegradation

    func testAllConfiguredButOneBackingOffMapsToDegradation() {
        let states: [ServiceID: MonitorState] = [
            .claude: .active(lastSuccessAt: Date()),
            .codex: .active(lastSuccessAt: Date()),
            .minimax: .backingOff(reason: .networkError, nextRetryIn: 60, attempt: 1),
        ]
        let snapshots: [ServiceID: UsageSnapshot] = [
            .claude: snapshot(.claude, 0.8),
            .codex: snapshot(.codex, 0.6),
            .minimax: snapshot(.minimax, 0.4),
        ]
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: snapshots)
        if case .allConfiguredWithDegradation(let states) = result {
            XCTAssertEqual(states.count, 3)
            if case .backingOff = states[.minimax] { /* ok */ } else {
                XCTFail("minimax should be backingOff")
            }
        } else {
            XCTFail("expected allConfiguredWithDegradation, got \(result)")
        }
    }

    // MARK: - State E — allServicesDown

    func testEveryServiceFailedMapsToAllServicesDown() {
        let states: [ServiceID: MonitorState] = [
            .claude: .backingOff(reason: .fileSystemError(message: "x"), nextRetryIn: 30, attempt: 1),
            .codex: .unconfigured(reason: .codexNotInstalled),
            .minimax: .backingOff(reason: .networkError, nextRetryIn: 60, attempt: 2),
        ]
        // No snapshots → no active.
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: [:])
        if case .allServicesDown(let states) = result {
            XCTAssertEqual(states.count, 3)
        } else {
            XCTFail("expected allServicesDown, got \(result)")
        }
    }

    // MARK: - State F — normalDashboard

    func testAllActiveWithSnapshotsMapsToNormal() {
        let states: [ServiceID: MonitorState] = [
            .claude: .active(lastSuccessAt: Date()),
            .codex: .active(lastSuccessAt: Date()),
            .minimax: .active(lastSuccessAt: Date()),
        ]
        let snapshots: [ServiceID: UsageSnapshot] = [
            .claude: snapshot(.claude, 0.8),
            .codex: snapshot(.codex, 0.7),
            .minimax: snapshot(.minimax, 0.5),
        ]
        let result = PopoverPresentation.resolve(monitorStates: states, snapshots: snapshots)
        if case .normalDashboard = result {
            // ok
        } else {
            XCTFail("expected normalDashboard, got \(result)")
        }
    }

    // MARK: - ServiceTileState derivation

    func testDeriveActiveWithSnapshot() {
        let snap = snapshot(.claude, 0.6)
        let state = ServiceTileState.derive(
            monitor: .active(lastSuccessAt: Date()),
            snapshot: snap
        )
        if case .active(let s) = state {
            XCTAssertEqual(s.usedFraction, 0.6)
        } else {
            XCTFail("expected active state")
        }
    }

    func testDeriveActiveWithoutSnapshotIsIdle() {
        let state = ServiceTileState.derive(
            monitor: .active(lastSuccessAt: Date()),
            snapshot: nil
        )
        XCTAssertEqual(state, .idle)
    }

    func testDeriveBackingOffPreservesStaleSnapshot() {
        let stale = snapshot(.minimax, 0.3)
        let state = ServiceTileState.derive(
            monitor: .backingOff(reason: .rateLimited, nextRetryIn: 60, attempt: 1),
            snapshot: stale
        )
        if case .backingOff(let s, let reason, let next) = state {
            XCTAssertEqual(s?.usedFraction, 0.3)
            XCTAssertEqual(reason, .rateLimited)
            XCTAssertEqual(next, 60)
        } else {
            XCTFail("expected backingOff")
        }
    }

    func testDeriveUnconfiguredCarriesReason() {
        let state = ServiceTileState.derive(
            monitor: .unconfigured(reason: .codexNotAuthenticated),
            snapshot: nil
        )
        XCTAssertEqual(state, .unconfigured(.codexNotAuthenticated))
    }

    func testDeriveIdleAlwaysIdle() {
        XCTAssertEqual(
            ServiceTileState.derive(monitor: .idle, snapshot: snapshot(.claude, 0.5)),
            .idle
        )
    }
}
