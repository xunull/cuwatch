import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// All visual decision tokens for cuwatch.
///
/// Source of truth: `DESIGN.md` at repo root. Update both together.
/// Theme: "Blackened-brass cockpit instrument from a 1960s analog computer."
public enum Tokens {

    // MARK: - Color (dark mode, the default)

    public enum DarkColor {
        /// Near-black background with a green-brown undertone, never pure #000.
        public static let bg = HexColor(0x0E0C0A)
        /// Popover surface.
        public static let surface = HexColor(0x171411)
        /// Raised row surface, hairlines.
        public static let surface2 = HexColor(0x211D18)
        /// Primary text (warm bone, never #FFFFFF).
        public static let ink = HexColor(0xE8DFD0)
        /// Muted text (labels, secondary metadata).
        public static let inkMute = HexColor(0xA39584)
        /// Dim text (timestamps, footer).
        public static let inkDim = HexColor(0x6B5F50)
        /// Aged brass: dial needle, progress bar fill, label tags.
        public static let brass = HexColor(0xC9A86A)
        /// Burnt orange: fires when used ≥ 70% on any service, or ghost line crosses 100% before reset.
        public static let warn = HexColor(0xD4823A)
        /// Oxidized iron-red: fires when used ≥ 90%, or window locked. No pulse, just red.
        public static let danger = HexColor(0xB8412E)
    }

    // MARK: - Color (light mode, parchment)

    public enum LightColor {
        /// Warm parchment background.
        public static let bg = HexColor(0xF2EDE3)
        public static let surface = HexColor(0xE8E0D2)
        public static let surface2 = HexColor(0xDDD3C0)
        public static let ink = HexColor(0x2A2520)
        public static let inkMute = HexColor(0x6B5F50)
        public static let inkDim = HexColor(0x9B8B78)
        /// Darker brass, same family as the dark-mode brass.
        public static let brass = HexColor(0x8B6B2F)
        public static let warn = HexColor(0xB8651F)
        public static let danger = HexColor(0x8B2A1E)
    }

    // MARK: - Increase Contrast palette (per /plan-design-review D5)

    public enum HighContrastDark {
        public static let bg = HexColor(0x000000)
        public static let ink = HexColor(0xFFFFFF)
        public static let brass = HexColor(0xFFD080)
        public static let warn = HexColor(0xFFA060)
        public static let danger = HexColor(0xFF6647)
    }

    // MARK: - Typography

    /// Locked type scale. NEVER add sizes.
    public enum Size {
        /// 10pt — uppercase labels with 0.14em tracking.
        public static let xs: CGFloat = 10
        /// 11pt — meta text (timestamps, footer).
        public static let s: CGFloat = 11
        /// 13pt — service percentages, body labels.
        public static let m: CGFloat = 13
        /// 15pt — body text in preferences, tooltips.
        public static let l: CGFloat = 15
        /// 22pt — sub-readout ("resets in 2h 14m").
        public static let xl: CGFloat = 22
        /// 34pt — main readout. Only one per popover.
        public static let display: CGFloat = 34
    }

    /// Letter-spacing in em units.
    public enum Tracking {
        public static let body: CGFloat = -0.01
        public static let display: CGFloat = -0.04
        public static let label: CGFloat = 0.14
    }

    /// Font family. **Removed 2026-06-21** — switched from bundled IBM Plex Mono
    /// to the system monospaced design font (SF Mono on macOS 13+, Menlo
    /// earlier). UI surfaces use `Font.system(.monospaced)` directly; there's
    /// no per-platform family string to lock in. See DESIGN.md Decisions Log.

    // MARK: - Spacing (4pt grid)

    /// Locked spacing tokens. NEVER deviate.
    public enum Space {
        public static let s4: CGFloat = 4
        public static let s8: CGFloat = 8
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
        public static let s48: CGFloat = 48
    }

    // MARK: - Layout

    public enum Layout {
        /// Popover width — locked. Required by the instrument anchor.
        public static let popoverWidth: CGFloat = 340
        /// Service row height in normal state.
        public static let rowHeight: CGFloat = 56
        /// Service row height when inline form is expanded.
        public static let rowHeightExpanded: CGFloat = 140
        /// Menu bar icon canvas (16x16).
        public static let menuBarIconSize: CGFloat = 16
        /// Header dial replica in popover.
        public static let dialBigSize: CGFloat = 48
        /// Hairline thickness.
        public static let hairline: CGFloat = 1
        /// Bar height in service row.
        public static let barHeight: CGFloat = 6
        /// Popover corner radius.
        public static let popoverCornerRadius: CGFloat = 12
    }

    // MARK: - Motion

    /// All animation durations. Event-driven only. Reduce Motion → instant.
    public enum Motion {
        /// Popover close fade.
        public static let micro: TimeInterval = 0.100
        /// Popover open fade + scale, inline row expand.
        public static let short: TimeInterval = 0.200
        /// Color crossfade (green→warn or warn→danger).
        public static let medium: TimeInterval = 0.350
        /// Needle settle (damped spring with overshoot).
        public static let needleSettle: TimeInterval = 0.280
        /// Warning pulse cadence at ≥ 80% remaining.
        public static let warningPulseInterval: TimeInterval = 30.0
        /// Coalescer debounce for popover updates (per outside voice #5).
        public static let coalesceDebounce: TimeInterval = 0.500
        /// Dial needle overshoot in degrees before settling back.
        public static let needleOvershoot: CGFloat = 4
    }

    // MARK: - Thresholds

    /// Color thresholds for menu bar dial and progress bars.
    /// v1 uses pure used %, NOT burn rate (per plan: "v1 不带预测").
    /// Vendor-aligned: matches Claude / Minimax console conventions where
    /// warnings appear closer to the cap (option B per /plan-eng-review
    /// 2026-06-21 D-reversal).
    public enum Threshold {
        /// Green / brass: < 70% used (lots of headroom).
        public static let greenUpperBound: Double = 0.70
        /// Yellow / warn: 70% — 90% used.
        public static let yellowLowerBound: Double = 0.70
        /// Red / danger: ≥ 90% used.
        public static let redLowerBound: Double = 0.90
        /// "Danger" lock state at ≥ 95% used (no pulse, just red).
        public static let dangerLockBound: Double = 0.95
    }

    // MARK: - Polling

    public enum Polling {
        public static let defaultIntervalSeconds: TimeInterval = 30
        public static let minIntervalSeconds: TimeInterval = 10
        public static let maxIntervalSeconds: TimeInterval = 300
        /// Backoff schedule for failed polls.
        public static let backoffSequenceSeconds: [TimeInterval] = [30, 60, 120, 300]
        public static let highFrequencyWarningThresholdSeconds: TimeInterval = 15
    }
}

/// Lightweight hex-to-color value that compiles on all platforms.
/// On macOS, can be converted to `NSColor` via `nsColor`.
public struct HexColor: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ rgb: UInt32, alpha: Double = 1.0) {
        self.red = Double((rgb >> 16) & 0xFF) / 255.0
        self.green = Double((rgb >> 8) & 0xFF) / 255.0
        self.blue = Double(rgb & 0xFF) / 255.0
        self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Hex string representation (e.g. "#0E0C0A").
    public var hexString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    #if canImport(AppKit)
    public var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}
