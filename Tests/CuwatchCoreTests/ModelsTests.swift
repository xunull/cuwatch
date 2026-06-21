import XCTest
@testable import CuwatchCore

final class ModelsTests: XCTestCase {

    func testServiceIDDisplayLabels() {
        XCTAssertEqual(ServiceID.claude.displayLabel, "CLAUDE")
        XCTAssertEqual(ServiceID.codex.displayLabel, "CODEX")
        XCTAssertEqual(ServiceID.minimax.displayLabel, "MINIMAX")
    }

    func testServiceIDOnboardingCTAs() {
        // Each service has a different auth model so the onboarding CTAs differ
        // (per /plan-eng-review D1).
        XCTAssertEqual(ServiceID.claude.onboardingCTA, "Grant Full Disk Access")
        XCTAssertEqual(ServiceID.codex.onboardingCTA, "Install codex CLI")
        XCTAssertEqual(ServiceID.minimax.onboardingCTA, "Paste API token")
    }

    func testServiceAuthModels() {
        if case .filesystemRead(let path) = ServiceID.claude.authModel {
            XCTAssertEqual(path, "~/.claude/projects/")
        } else {
            XCTFail("Claude should be filesystem-read auth")
        }
        if case .filesystemRead(let path) = ServiceID.codex.authModel {
            XCTAssertEqual(path, "~/.codex/")
        } else {
            XCTFail("Codex should be filesystem-read auth")
        }
        XCTAssertEqual(ServiceID.minimax.authModel, .bearerToken)
    }

    func testUsageSnapshotClampsUsedFraction() {
        let over = UsageSnapshot(
            service: .claude,
            readAt: Date(),
            window: .sessionWindow5h,
            usedFraction: 1.5,
            resetAt: nil
        )
        XCTAssertEqual(over.usedFraction, 1.0)

        let under = UsageSnapshot(
            service: .claude,
            readAt: Date(),
            window: .sessionWindow5h,
            usedFraction: -0.5,
            resetAt: nil
        )
        XCTAssertEqual(under.usedFraction, 0.0)
    }

    func testColorStateAtThresholdBoundaries() {
        // Vendor-aligned thresholds (option B per /plan-eng-review 2026-06-21):
        //   < 70% used  → normal (green)
        //   70-90% used → warn (yellow)
        //   ≥ 90% used  → danger (red)

        // Just below 0.70 → normal.
        let justBelowWarn = UsageSnapshot(
            service: .claude, readAt: Date(), window: .sessionWindow5h,
            usedFraction: 0.6999, resetAt: nil
        )
        XCTAssertEqual(justBelowWarn.colorState, .normal)

        // At exactly 0.70 → warn (warn inclusive lower bound).
        let atWarnEdge = UsageSnapshot(
            service: .claude, readAt: Date(), window: .sessionWindow5h,
            usedFraction: 0.70, resetAt: nil
        )
        XCTAssertEqual(atWarnEdge.colorState, .warn)

        // Just below 0.90 → still warn.
        let justBelowDanger = UsageSnapshot(
            service: .claude, readAt: Date(), window: .sessionWindow5h,
            usedFraction: 0.8999, resetAt: nil
        )
        XCTAssertEqual(justBelowDanger.colorState, .warn)

        // At exactly 0.90 → danger (red inclusive lower bound).
        let atDangerEdge = UsageSnapshot(
            service: .claude, readAt: Date(), window: .sessionWindow5h,
            usedFraction: 0.90, resetAt: nil
        )
        XCTAssertEqual(atDangerEdge.colorState, .danger)
    }

    func testUsageDisplayCombined() {
        let display = UsageDisplay(used: "58", total: "100", unit: "yuan")
        XCTAssertEqual(display.combined, "58 of 100 yuan")
    }

    func testBackoffScheduleClampsToFinalEntry() {
        let s = BackoffSchedule.default
        XCTAssertEqual(s.interval(forAttempt: 0), 30)
        XCTAssertEqual(s.interval(forAttempt: 1), 60)
        XCTAssertEqual(s.interval(forAttempt: 2), 120)
        XCTAssertEqual(s.interval(forAttempt: 3), 300)
        // Beyond defined entries → caps at last.
        XCTAssertEqual(s.interval(forAttempt: 99), 300)
        // Negative → caps at first.
        XCTAssertEqual(s.interval(forAttempt: -1), 30)
    }
}
