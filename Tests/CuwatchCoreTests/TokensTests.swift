import XCTest
@testable import CuwatchCore

final class TokensTests: XCTestCase {

    func testHexColorRoundTripping() {
        // Brass and danger hex strings must serialize back to canonical uppercase form.
        XCTAssertEqual(Tokens.DarkColor.brass.hexString, "#C9A86A")
        XCTAssertEqual(Tokens.DarkColor.danger.hexString, "#B8412E")
        XCTAssertEqual(Tokens.DarkColor.bg.hexString, "#0E0C0A")
        XCTAssertEqual(Tokens.LightColor.bg.hexString, "#F2EDE3")
    }

    func testHexColorComponentRange() {
        // Every defined color must be in [0,1] for each component.
        let allDark: [HexColor] = [
            Tokens.DarkColor.bg, Tokens.DarkColor.surface, Tokens.DarkColor.surface2,
            Tokens.DarkColor.ink, Tokens.DarkColor.inkMute, Tokens.DarkColor.inkDim,
            Tokens.DarkColor.brass, Tokens.DarkColor.warn, Tokens.DarkColor.danger,
        ]
        for c in allDark {
            XCTAssertTrue((0.0...1.0).contains(c.red))
            XCTAssertTrue((0.0...1.0).contains(c.green))
            XCTAssertTrue((0.0...1.0).contains(c.blue))
            XCTAssertEqual(c.alpha, 1.0)
        }
    }

    func testTypographyScale() {
        // The locked scale must be exactly these six values, ascending.
        let scale = [
            Tokens.Size.xs, Tokens.Size.s, Tokens.Size.m,
            Tokens.Size.l, Tokens.Size.xl, Tokens.Size.display,
        ]
        XCTAssertEqual(scale, [10, 11, 13, 15, 22, 34])
        // Strictly ascending — no duplicates.
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
    }

    func testSpacingScale() {
        let spacing = [
            Tokens.Space.s4, Tokens.Space.s8, Tokens.Space.s12, Tokens.Space.s16,
            Tokens.Space.s24, Tokens.Space.s32, Tokens.Space.s48,
        ]
        XCTAssertEqual(spacing, [4, 8, 12, 16, 24, 32, 48])
        // Every value must be a multiple of 4 (4pt baseline grid).
        for v in spacing {
            XCTAssertEqual(v.truncatingRemainder(dividingBy: 4), 0, "\(v) not on 4pt grid")
        }
    }

    func testThresholdLadder() {
        // Used semantics, vendor-aligned (option B per /plan-eng-review
        // 2026-06-21): green < 70%, yellow 70-90%, red ≥ 90%.
        XCTAssertEqual(Tokens.Threshold.greenUpperBound, 0.70)
        XCTAssertEqual(Tokens.Threshold.yellowLowerBound, 0.70)
        XCTAssertEqual(Tokens.Threshold.redLowerBound, 0.90)
        XCTAssertLessThan(Tokens.Threshold.yellowLowerBound, Tokens.Threshold.redLowerBound)
    }

    func testPollingCadence() {
        XCTAssertEqual(Tokens.Polling.defaultIntervalSeconds, 30)
        XCTAssertEqual(Tokens.Polling.minIntervalSeconds, 10)
        XCTAssertEqual(Tokens.Polling.maxIntervalSeconds, 300)
        // Backoff sequence must be monotonic non-decreasing.
        let backoff = Tokens.Polling.backoffSequenceSeconds
        XCTAssertFalse(backoff.isEmpty)
        for i in 1..<backoff.count {
            XCTAssertGreaterThanOrEqual(backoff[i], backoff[i-1])
        }
    }

    func testMotionDurations() {
        // All durations must be on the locked set {0.1, 0.2, 0.35, 0.28, 0.5}.
        let durations: Set<TimeInterval> = [
            Tokens.Motion.micro,
            Tokens.Motion.short,
            Tokens.Motion.medium,
            Tokens.Motion.needleSettle,
            Tokens.Motion.coalesceDebounce,
        ]
        XCTAssertEqual(durations, [0.100, 0.200, 0.350, 0.280, 0.500])
    }
}
