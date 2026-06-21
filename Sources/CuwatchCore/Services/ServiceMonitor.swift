import Foundation

/// One independent monitor per service (Claude, Codex, Minimax).
///
/// Per /plan-eng-review D3, cuwatch uses three independent `ServiceMonitor` instances
/// instead of a unified coordinator — this gives per-service failure isolation:
/// Minimax network outage doesn't stop Claude / Codex polls, and vice versa.
///
/// ```
/// ┌─────────────────────────────────────────────────────────┐
/// │                  cuwatch process                         │
/// │                                                          │
/// │  ┌──────────┐    ┌──────────┐    ┌──────────┐          │
/// │  │ ClaudeMon│    │ CodexMon │    │MinimaxMon│          │
/// │  │ timer:30s│    │ timer:30s│    │ timer:30s│          │
/// │  │ backoff: │    │ backoff: │    │ backoff: │          │
/// │  │  30→60→  │    │  30→60→  │    │  30→60→  │          │
/// │  │  300s    │    │  300s    │    │  300s    │          │
/// │  └────┬─────┘    └────┬─────┘    └────┬─────┘          │
/// │       │               │               │                 │
/// │       ▼               ▼               ▼                 │
/// │   readClaude()   readCodex()    HTTPS Minimax           │
/// │       │               │               │                 │
/// │       └───────┬───────┴───────┬───────┘                 │
/// │               ▼               ▼                         │
/// │         StateStore (publishes UsageSnapshot)            │
/// └─────────────────────────────────────────────────────────┘
/// ```
public protocol ServiceMonitor: AnyObject, Sendable {
    /// Which service this monitor is for.
    var serviceID: ServiceID { get }

    /// Start polling. Calls into the `StateStore` on every successful read,
    /// and into the configured failure observer on errors.
    func start() async

    /// Stop polling. Idempotent.
    func stop() async

    /// Trigger an immediate poll outside the scheduled cadence (e.g. on wake from sleep).
    func pollNow() async
}

/// Operating state of a service monitor.
public enum MonitorState: Equatable, Sendable {
    /// Hasn't been started yet, or fully stopped.
    case idle
    /// Polling normally.
    case active(lastSuccessAt: Date)
    /// Last poll failed; waiting `nextRetryIn` seconds before next attempt.
    case backingOff(reason: MonitorFailureReason, nextRetryIn: TimeInterval, attempt: Int)
    /// Permanently un-pollable in this session (e.g. token missing).
    /// Caller can resume by reconfiguring and calling `pollNow()`.
    case unconfigured(reason: UnconfiguredReason)
}

/// Why a poll failed (transient).
public enum MonitorFailureReason: Equatable, Sendable {
    case networkError
    case authExpired
    case rateLimited
    case timeout
    case fileSystemError(message: String)
    case parseError(message: String)
}

/// Why a service is currently not configurable.
public enum UnconfiguredReason: Equatable, Sendable {
    /// User has not granted Full Disk Access to read `~/.claude/projects/`.
    case missingFullDiskAccess
    /// `codex` CLI binary not installed on `PATH`.
    case codexNotInstalled
    /// `codex` CLI is installed but not authenticated.
    case codexNotAuthenticated
    /// No Minimax bearer token in Keychain.
    case minimaxTokenMissing
}

/// Backoff schedule used by all monitors. Per plan NFR table:
///   30s → 60s → 120s → 300s (cap).
/// Reset to base on next success.
public struct BackoffSchedule: Sendable {
    public let intervals: [TimeInterval]

    public static let `default` = BackoffSchedule(
        intervals: Tokens.Polling.backoffSequenceSeconds
    )

    public init(intervals: [TimeInterval]) {
        precondition(!intervals.isEmpty, "BackoffSchedule must have ≥1 interval")
        self.intervals = intervals
    }

    /// Pick the next sleep interval given a 0-based attempt count.
    /// `attempt = 0` → first retry, `attempt = 1` → second, …
    /// Capped at the final entry.
    public func interval(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(0, min(attempt, intervals.count - 1))
        return intervals[clamped]
    }
}
