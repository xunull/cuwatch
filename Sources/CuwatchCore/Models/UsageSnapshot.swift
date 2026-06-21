import Foundation

/// A single point-in-time read of a service's usage state.
///
/// Each `ServiceMonitor` publishes one of these into `StateStore` on a successful poll.
/// Populated fields depend on what the service exposes.
public struct UsageSnapshot: Equatable, Sendable {

    /// The service this snapshot is for.
    public let service: ServiceID

    /// When this snapshot was read (wall clock).
    public let readAt: Date

    /// Window kind (5h session, weekly, or token budget).
    public let window: WindowKind

    /// Used fraction in [0.0, 1.0]. 0.0 = nothing used (full headroom),
    /// 1.0 = fully consumed.
    ///
    /// Used semantics chosen 2026-06-21 to match vendor dashboards
    /// (Claude / Minimax consoles both display "X% used"). Previously
    /// stored remaining; the reversal is logged in decisions.active.json.
    ///
    /// For window-based services, this is `elapsed / window_size`.
    /// For token-budget services (Minimax), it's `(total - remaining) / total`.
    public let usedFraction: Double

    /// When this window resets to full. `nil` if the service has no explicit reset boundary.
    public let resetAt: Date?

    /// Optional absolute usage breakdown for display (e.g. "3 of 100 yuan",
    /// "168k of 200k tokens").
    public let usageDisplay: UsageDisplay?

    public init(
        service: ServiceID,
        readAt: Date,
        window: WindowKind,
        usedFraction: Double,
        resetAt: Date?,
        usageDisplay: UsageDisplay? = nil
    ) {
        self.service = service
        self.readAt = readAt
        self.window = window
        self.usedFraction = max(0.0, min(1.0, usedFraction))
        self.resetAt = resetAt
        self.usageDisplay = usageDisplay
    }

    /// Where this snapshot falls in the color-state ladder.
    /// Vendor-aligned thresholds (option B per /plan-eng-review 2026-06-21):
    ///   - Green / normal: < 70% used (lots of headroom)
    ///   - Yellow / warn: 70-90% used (caution)
    ///   - Red / danger: ≥ 90% used (almost gone)
    public var colorState: ColorState {
        if usedFraction >= Tokens.Threshold.redLowerBound {
            return .danger
        } else if usedFraction >= Tokens.Threshold.yellowLowerBound {
            return .warn
        } else {
            return .normal
        }
    }
}

/// What kind of quota/window this service exposes.
public enum WindowKind: Equatable, Sendable {
    /// Claude Code Plan or ChatGPT Plus / Pro Codex CLI — rolling 5-hour session window.
    case sessionWindow5h
    /// Plan weekly cap.
    case weekly
    /// Token-budget pool (Minimax Token Plan).
    case tokenBudget
}

/// A pre-formatted "X of Y" used display, used in the right-side meta column.
public struct UsageDisplay: Equatable, Sendable {
    public let used: String
    public let total: String
    public let unit: String

    public init(used: String, total: String, unit: String) {
        self.used = used
        self.total = total
        self.unit = unit
    }

    public var combined: String {
        "\(used) of \(total) \(unit)"
    }
}

/// Three-tier color state used by the menu bar dial and progress bars.
public enum ColorState: String, Sendable {
    case normal
    case warn
    case danger
}
