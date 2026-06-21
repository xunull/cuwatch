import Foundation
import CoreGraphics

/// Pure-data model for the menu bar dial.
///
/// Everything the renderer needs to draw a frame: arc geometry, needle angle,
/// tick mark angle, color palette. No AppKit, no CALayer, no animation — those
/// belong to `DialView`. This is testable from XCTest.
///
/// Geometry convention:
/// - Standard mathematical degrees (0° = East, 90° = North, 180° = West, 270° = South).
/// - Cocoa NSView default coordinates are y-up, so cos/sin map directly.
/// - The dial arc spans 270° from start at 225° (SW) clockwise through 90° (N)
///   to end at -45°/315° (SE), leaving 90° open at the bottom (around 270° / S).
public struct DialModel: Equatable, Sendable {

    // MARK: - Inputs

    /// Used fraction of the most-constrained resource, in [0.0, 1.0].
    /// 0.0 → needle at arc start (SW, "full"). 1.0 → needle at arc end (SE, "empty").
    /// Semantics flipped from remaining → used 2026-06-21 to align with vendor
    /// dashboards.
    public let fraction: Double

    /// Which state ladder we're on (drives arc and needle colors).
    public let state: DialColorState

    /// Which menu bar appearance we're rendering for.
    public let appearance: DialAppearance

    public init(fraction: Double, state: DialColorState, appearance: DialAppearance) {
        self.fraction = max(0.0, min(1.0, fraction))
        self.state = state
        self.appearance = appearance
    }

    // MARK: - Geometry constants

    /// Start of the arc — 225° standard math, i.e. SW direction. Needle at fraction = 1.0.
    public static let arcStartDegrees: Double = 225

    /// End of the arc — going clockwise (in math = decreasing degrees) to -45° (= 315°), i.e. SE.
    /// Needle at fraction = 0.0.
    public static let arcEndDegrees: Double = -45

    /// Total sweep, 270°.
    public static let arcSweepDegrees: Double = 270

    /// Position of the redline tick mark, measured as a fraction of arc traveled from start.
    /// At 75% used, so we set the tick at fraction = 0.75.
    public static let redlineFraction: Double = 0.75

    // MARK: - Derived geometry

    /// Needle angle in standard math degrees. As `fraction` (used) increases from 0 to 1,
    /// the angle moves from `arcStartDegrees` (225°, SW) clockwise to `arcEndDegrees` (-45°, SE).
    public var needleAngleDegrees: Double {
        // At fraction=0 → arcStartDegrees (225°). At fraction=1 → arcEndDegrees (-45°).
        // Linear interpolation.
        Self.arcStartDegrees + (Self.arcEndDegrees - Self.arcStartDegrees) * fraction
    }

    /// Same as above in radians.
    public var needleAngleRadians: Double {
        needleAngleDegrees * .pi / 180
    }

    /// Tick mark angle (the 75%-used redline) in standard math degrees.
    public static var tickAngleDegrees: Double {
        arcStartDegrees + (arcEndDegrees - arcStartDegrees) * redlineFraction
    }

    public static var tickAngleRadians: Double {
        tickAngleDegrees * .pi / 180
    }

    /// Unit-radius needle endpoint relative to the dial center (y-up coordinate system).
    /// Multiply by needle length to get actual screen point.
    public var needleEndpointUnit: CGPoint {
        let a = needleAngleRadians
        return CGPoint(x: cos(a), y: sin(a))
    }

    /// Unit-radius position of the tick mark.
    public static var tickEndpointUnit: CGPoint {
        let a = tickAngleRadians
        return CGPoint(x: cos(a), y: sin(a))
    }

    // MARK: - Color palette

    /// The arc (background ring) color for this appearance + state combination.
    public var arcColor: HexColor {
        switch (appearance, state) {
        case (.darkMenuBar, .brass):        return Tokens.DarkColor.inkMute
        case (.darkMenuBar, .burntOrange):  return Tokens.DarkColor.inkMute
        case (.darkMenuBar, .oxidizedRed):  return Tokens.DarkColor.danger
        case (.darkMenuBar, .neutralGrey):  return Tokens.DarkColor.inkDim
        case (.lightMenuBar, .brass):       return HexColor(0x4A4238)
        case (.lightMenuBar, .burntOrange): return HexColor(0x4A4238)
        case (.lightMenuBar, .oxidizedRed): return Tokens.LightColor.danger
        case (.lightMenuBar, .neutralGrey): return HexColor(0x9B8B78)
        case (.tintedMenuBar, _):
            // Template mode — the system tints everything in `inkColor`.
            return Tokens.DarkColor.ink
        }
    }

    /// The needle color for this appearance + state combination.
    public var needleColor: HexColor {
        switch (appearance, state) {
        case (.darkMenuBar, .brass),
             (.darkMenuBar, .burntOrange):
            return Tokens.DarkColor.ink
        case (.darkMenuBar, .oxidizedRed):
            // No second tone in danger — the whole dial reads red.
            return Tokens.DarkColor.danger
        case (.darkMenuBar, .neutralGrey):
            return Tokens.DarkColor.inkMute
        case (.lightMenuBar, .brass),
             (.lightMenuBar, .burntOrange):
            return HexColor(0x1F1A14)
        case (.lightMenuBar, .oxidizedRed):
            return Tokens.LightColor.danger
        case (.lightMenuBar, .neutralGrey):
            return Tokens.LightColor.inkMute
        case (.tintedMenuBar, _):
            return Tokens.DarkColor.ink
        }
    }

    /// The 75%-consumed redline tick color for this appearance + state combination.
    public var tickColor: HexColor {
        switch (appearance, state) {
        case (.darkMenuBar, _):
            return Tokens.DarkColor.brass
        case (.lightMenuBar, _):
            return Tokens.LightColor.brass
        case (.tintedMenuBar, _):
            return Tokens.DarkColor.ink
        }
    }

    /// Whether we should render in template mode (single color, system tints).
    /// Applies to the accent-tinted menu bar where the OS expects monochrome icons
    /// it can tint with the accent color.
    public var isTemplate: Bool {
        appearance == .tintedMenuBar
    }
}

/// Which menu bar appearance is currently active. Determined by sampling
/// `NSAppearance.current` at draw time (DialView's responsibility).
public enum DialAppearance: Equatable, Sendable {
    case darkMenuBar
    case lightMenuBar
    /// Menu bar is tinted by user's accent color setting. We render template-style
    /// (single color) and let the system tint take over.
    case tintedMenuBar
}
