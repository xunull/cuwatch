import XCTest
import CoreGraphics
@testable import CuwatchCore

final class DialModelTests: XCTestCase {

    private func dial(_ fraction: Double, _ state: DialColorState = .neutralGrey,
                      _ appearance: DialAppearance = .darkMenuBar) -> DialModel {
        DialModel(fraction: fraction, state: state, appearance: appearance)
    }

    // MARK: - Geometry

    func testNeedleAtFullPointsToArcStart() {
        // Used semantics: fraction = 0.0 (nothing used = full) → arc start = 225° (SW).
        let m = dial(0.0)
        XCTAssertEqual(m.needleAngleDegrees, DialModel.arcStartDegrees, accuracy: 0.001)
    }

    func testNeedleAtEmptyPointsToArcEnd() {
        // Used semantics: fraction = 1.0 (fully consumed = empty) → arc end = -45° (SE).
        let m = dial(1.0)
        XCTAssertEqual(m.needleAngleDegrees, DialModel.arcEndDegrees, accuracy: 0.001)
    }

    func testNeedleAtHalfPointsToTop() {
        // Mid-fraction 0.5 → midpoint of sweep.
        // arcStart=225, arcEnd=-45 → midpoint angle: 225 + (-45-225) * 0.5 = 225 - 135 = 90°. Straight up.
        let m = dial(0.5)
        XCTAssertEqual(m.needleAngleDegrees, 90.0, accuracy: 0.001)
    }

    func testNeedleAngleClampsAtBoundaries() {
        // Used semantics (2026-06-21 flip):
        //   fraction = 0 (nothing used)  → needle at arc START (SW, "full")
        //   fraction = 1 (fully consumed) → needle at arc END (SE, "empty")
        // Over-range fractions clamp to [0, 1].
        XCTAssertEqual(dial(-0.5).needleAngleDegrees, DialModel.arcStartDegrees, accuracy: 0.001)
        XCTAssertEqual(dial(1.5).needleAngleDegrees, DialModel.arcEndDegrees, accuracy: 0.001)
    }

    func testNeedleAngleMonotonicAsUsedFractionIncreases() {
        // As used fraction increases 0 → 1, angle decreases monotonically
        // from arcStart (225°) to arcEnd (-45°).
        var lastAngle = dial(0.0).needleAngleDegrees
        for f in stride(from: 0.05, through: 1.0, by: 0.05) {
            let angle = dial(f).needleAngleDegrees
            XCTAssertLessThanOrEqual(angle, lastAngle, "at fraction \(f) angle did not decrease monotonically")
            lastAngle = angle
        }
    }

    func testNeedleEndpointUnit() {
        // At fraction = 0.5 → needle points straight up (math 90°), so unit endpoint is (0, 1).
        let m = dial(0.5)
        let p = m.needleEndpointUnit
        XCTAssertEqual(p.x, 0, accuracy: 0.0001)
        XCTAssertEqual(p.y, 1, accuracy: 0.0001)
    }

    func testTickAt75PercentUsed() {
        // Tick fraction is 0.75 (75% used). Tick angle == needle angle at 0.75 used.
        let needleAt75 = dial(0.75).needleAngleDegrees
        XCTAssertEqual(DialModel.tickAngleDegrees, needleAt75, accuracy: 0.001)
    }

    func testArcSpanIs270Degrees() {
        // arcStart - arcEnd = 270 in our parameterization (225 - (-45)).
        let span = DialModel.arcStartDegrees - DialModel.arcEndDegrees
        XCTAssertEqual(span, 270.0)
        XCTAssertEqual(DialModel.arcSweepDegrees, 270.0)
    }

    // MARK: - Palette: dark menu bar

    func testDarkArcColorByState() {
        XCTAssertEqual(dial(0.8, .brass, .darkMenuBar).arcColor, Tokens.DarkColor.inkMute)
        XCTAssertEqual(dial(0.3, .burntOrange, .darkMenuBar).arcColor, Tokens.DarkColor.inkMute)
        // Danger flips the WHOLE arc red — no second tone in danger.
        XCTAssertEqual(dial(0.1, .oxidizedRed, .darkMenuBar).arcColor, Tokens.DarkColor.danger)
        XCTAssertEqual(dial(1.0, .neutralGrey, .darkMenuBar).arcColor, Tokens.DarkColor.inkDim)
    }

    func testDarkNeedleColorByState() {
        // Normal / warn → warm bone (ink). Danger → no contrast needle, also red.
        XCTAssertEqual(dial(0.8, .brass, .darkMenuBar).needleColor, Tokens.DarkColor.ink)
        XCTAssertEqual(dial(0.3, .burntOrange, .darkMenuBar).needleColor, Tokens.DarkColor.ink)
        XCTAssertEqual(dial(0.05, .oxidizedRed, .darkMenuBar).needleColor, Tokens.DarkColor.danger)
        XCTAssertEqual(dial(1.0, .neutralGrey, .darkMenuBar).needleColor, Tokens.DarkColor.inkMute)
    }

    func testDarkTickColorAlwaysBrass() {
        XCTAssertEqual(dial(0.8, .brass, .darkMenuBar).tickColor, Tokens.DarkColor.brass)
        XCTAssertEqual(dial(0.05, .oxidizedRed, .darkMenuBar).tickColor, Tokens.DarkColor.brass)
        XCTAssertEqual(dial(1.0, .neutralGrey, .darkMenuBar).tickColor, Tokens.DarkColor.brass)
    }

    // MARK: - Palette: light menu bar

    func testLightArcAndNeedleColors() {
        // Light mode uses darker palette for high contrast on parchment.
        XCTAssertEqual(dial(0.8, .brass, .lightMenuBar).arcColor, HexColor(0x4A4238))
        XCTAssertEqual(dial(0.8, .brass, .lightMenuBar).needleColor, HexColor(0x1F1A14))
        XCTAssertEqual(dial(0.05, .oxidizedRed, .lightMenuBar).arcColor, Tokens.LightColor.danger)
    }

    func testLightTickColorAlwaysLightBrass() {
        XCTAssertEqual(dial(0.8, .brass, .lightMenuBar).tickColor, Tokens.LightColor.brass)
    }

    // MARK: - Palette: tinted (template mode)

    func testTintedIsTemplate() {
        XCTAssertTrue(dial(0.5, .brass, .tintedMenuBar).isTemplate)
        XCTAssertFalse(dial(0.5, .brass, .darkMenuBar).isTemplate)
        XCTAssertFalse(dial(0.5, .brass, .lightMenuBar).isTemplate)
    }

    func testTintedColorsAreSingleTone() {
        // Template mode renders single-color; arc/needle/tick all the same so the
        // system can tint as one shape.
        let m = dial(0.5, .brass, .tintedMenuBar)
        XCTAssertEqual(m.arcColor, Tokens.DarkColor.ink)
        XCTAssertEqual(m.needleColor, Tokens.DarkColor.ink)
        XCTAssertEqual(m.tickColor, Tokens.DarkColor.ink)
    }

    // MARK: - Equatability

    func testEquatableConsidersAllFields() {
        let a = dial(0.5, .brass, .darkMenuBar)
        let b = dial(0.5, .brass, .darkMenuBar)
        let c = dial(0.5, .brass, .lightMenuBar)
        let d = dial(0.5, .burntOrange, .darkMenuBar)
        let e = dial(0.6, .brass, .darkMenuBar)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
        XCTAssertNotEqual(a, e)
    }
}
