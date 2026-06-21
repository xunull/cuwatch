import Foundation

/// Reads ChatGPT Codex CLI usage from `~/.codex/`.
///
/// Status (2026-06-13): **the wire format of the `~/.codex/` state files is not
/// fully reverse-engineered yet**. Per plan-eng-review D2 the cuwatch Codex
/// spike is allowed to study CodexBar's source (the steipete/codexbar Swift
/// app already reads these files) but not to copy its code. The actual JSON
/// schema needs to come back from Phase 0 Day 1-2 spike work.
///
/// This file ships the contract + the easy parts:
/// - Probe whether `codex` is on `PATH`.
/// - Probe whether `~/.codex/auth.json` exists.
/// - Return a `Probe` result so the `ServiceMonitor` can publish the right
///   `MonitorState` (.unconfigured vs .active) without committing to a snapshot.
/// - Snapshot extraction is a `// TODO: spike` stub that returns `nil` until
///   the spike confirms how to read the 5h-window remaining count.
///
/// Architecture:
/// ```
///   ┌────────────────────────────────────────────────────────────┐
///   │ CodexReader.read(now:)                                     │
///   │   1. probe `codex` binary on PATH                          │
///   │      → not installed: .codexNotInstalled                   │
///   │   2. probe ~/.codex/auth.json                              │
///   │      → not present:   .codexNotAuthenticated               │
///   │   3. read ~/.codex/sessions/*.json  (spike-pending)        │
///   │      → ParsedSession with tokens-used + window-start       │
///   │   4. emit UsageSnapshot (time-remaining in 5h window)      │
///   └────────────────────────────────────────────────────────────┘
/// ```
public final class CodexReader {

    /// 5h session window (matches Claude Code Plan).
    public static let sessionWindow: TimeInterval = 5 * 60 * 60

    public struct Result: Equatable, Sendable {
        public let snapshot: UsageSnapshot?
        public let probe: Probe
    }

    /// Outcome of probing the local environment for Codex availability.
    public enum Probe: Equatable, Sendable {
        /// `codex` binary not found on PATH.
        case binaryNotInstalled
        /// `codex` binary present but `~/.codex/auth.json` missing (or empty).
        case notAuthenticated
        /// `codex` is installed + authenticated. `sessionStart` is the start of
        /// the active 5h window if we could parse one. `nil` means we found
        /// the directory but the spike-pending parser hasn't extracted data yet.
        case authenticated(sessionStart: Date?)
    }

    public let homeDirectory: URL
    private let fileManager: FileManager

    public init(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.fileManager = fileManager
    }

    // MARK: - Public API

    public func read(now: Date = Date()) -> Result {
        let probe = probeEnvironment()
        switch probe {
        case .binaryNotInstalled, .notAuthenticated:
            return Result(snapshot: nil, probe: probe)
        case .authenticated(let sessionStart):
            // 2026-06-21: each rollout file's events carry
            // `payload.rate_limits.{primary,secondary}.used_percent + resets_at` —
            // the EXACT numbers the Codex desktop app / `codex usage` displays.
            // Read those directly; fall back to time-based proxy only if
            // rollout files exist but contain no rate_limits yet (extremely
            // unlikely — every server response writes them).
            if let snapshot = makeSnapshotFromRateLimits(now: now) {
                return Result(snapshot: snapshot, probe: probe)
            }
            // Fallback: time-based proxy. Honest about its limitations —
            // see DESIGN.md and README "What works today".
            guard let sessionStart else {
                return Result(snapshot: nil, probe: probe)
            }
            return Result(snapshot: makeTimeBasedSnapshot(sessionStart: sessionStart, now: now), probe: probe)
        }
    }

    // MARK: - Probing

    /// Look at `~/.codex/` to decide which probe bucket we're in.
    ///
    /// **Why we don't probe `$PATH` (changed 2026-06-21):** macOS GUI apps
    /// inherit the system-default PATH `/usr/bin:/bin:/usr/sbin:/sbin`, NOT
    /// the user's shell PATH. So a perfectly installed codex CLI at
    /// `/opt/homebrew/bin/codex` or `~/.local/bin/codex` looks "missing" to
    /// any sandboxed / `.accessory` GUI app like cuwatch. Filesystem probe
    /// against `~/.codex/` is the right signal — the CLI creates this
    /// directory on first run and it survives across reinstalls, so its
    /// presence is a more reliable "user has codex" check than walking PATH.
    public func probeEnvironment() -> Probe {
        guard codexInstallDirectoryExists() else { return .binaryNotInstalled }
        guard authFileExists() else { return .notAuthenticated }
        return .authenticated(sessionStart: detectSessionStart())
    }

    /// Treat the existence of `~/.codex/` as "codex CLI has been installed
    /// at some point". This is what we actually care about — we read data
    /// from this directory, not from the binary.
    private func codexInstallDirectoryExists() -> Bool {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: codexDirectory.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private var codexDirectory: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    private func authFileExists() -> Bool {
        let authFile = codexDirectory.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authFile.path) else { return false }
        // Treat empty file as "not authenticated" — partial install state.
        let attrs = try? fileManager.attributesOfItem(atPath: authFile.path)
        if let size = attrs?[.size] as? Int, size == 0 { return false }
        return true
    }

    /// Verified 2026-06-21 against real codex CLI install:
    ///   - Session files live at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
    ///     (3 levels deep, NOT flat — the original spike assumption was wrong)
    ///   - Filename encodes the exact session start time:
    ///     `rollout-2026-06-21T17-30-12-<uuid>.jsonl`
    ///   - Using filename > using mtime: codex CLI silently touches old
    ///     rollout files during background bookkeeping (an old June 11 file
    ///     shows up with today's mtime). Filename parsing avoids that
    ///     false-positive entirely.
    ///
    /// Returns the EARLIEST session start within the last 5h, treating that
    /// as the start of the active session (matches Claude's same-semantic
    /// fixed-window logic). Returns nil when no rollout file in window.
    private func detectSessionStart() -> Date? {
        let sessionsDir = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsDir.path) else { return nil }

        let cutoff = Date().addingTimeInterval(-Self.sessionWindow)
        var earliestRecent: Date? = nil

        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let start = Self.sessionStartFromFilename(url.lastPathComponent) else { continue }
            guard start >= cutoff else { continue }
            if earliestRecent == nil || start < earliestRecent! {
                earliestRecent = start
            }
        }
        return earliestRecent
    }

    /// Parses `rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl` filename into the
    /// encoded session-start `Date`. Returns nil on any format deviation
    /// (defensive — better to under-report than to surface garbage).
    /// Internal-but-static so tests can hit it directly.
    static func sessionStartFromFilename(_ filename: String) -> Date? {
        guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
        let stem = filename
            .replacingOccurrences(of: ".jsonl", with: "")
        let parts = stem.split(separator: "-")
        // Expected layout: ["rollout", "YYYY", "MM", "DDTHH", "MM", "SS", "<uuid>", ...].
        guard parts.count >= 7, parts[0] == "rollout" else { return nil }
        let timestampString = parts[1...5].joined(separator: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Filename uses local-clock timestamp without timezone marker, so
        // interpret in current TZ.
        formatter.timeZone = TimeZone.current
        return formatter.date(from: timestampString)
    }

    private func makeTimeBasedSnapshot(sessionStart: Date, now: Date) -> UsageSnapshot {
        let total = Self.sessionWindow
        let elapsed = max(0, min(total, now.timeIntervalSince(sessionStart)))
        let fraction = elapsed / total
        return UsageSnapshot(
            service: .codex,
            readAt: now,
            window: .sessionWindow5h,
            usedFraction: fraction,
            resetAt: sessionStart.addingTimeInterval(total)
        )
    }

    // MARK: - Real rate_limits parsing (2026-06-21)

    /// Returns the most-recent `rate_limits` block seen across all rollout
    /// files (capped to N most-recent files by filename time). Returns nil
    /// if no `payload.rate_limits` ever surfaces — extremely unlikely for a
    /// codex CLI that has handled even one server response.
    private func makeSnapshotFromRateLimits(now: Date) -> UsageSnapshot? {
        let sessionsDir = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsDir.path) else { return nil }

        // Collect (url, start) pairs across the tree.
        var candidates: [(URL, Date)] = []
        guard let enumerator = fileManager.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let start = Self.sessionStartFromFilename(url.lastPathComponent) else { continue }
            candidates.append((url, start))
        }
        // Latest first — the most recent rollout has the freshest rate_limits.
        candidates.sort { $0.1 > $1.1 }

        // Cap the scan: only look at up to 5 most-recent files. If the very
        // newest file is empty mid-write or hasn't received a server response
        // yet, we want to consult the prior session's last rate_limits.
        for entry in candidates.prefix(5) {
            if let limits = Self.lastRateLimits(in: entry.0) {
                return Self.snapshot(from: limits, now: now)
            }
        }
        return nil
    }

    /// Stream-parses a single rollout JSONL file line-by-line and returns
    /// the LAST `payload.rate_limits` block encountered. Static + internal
    /// so tests can hit it directly without instantiating CodexReader.
    static func lastRateLimits(in url: URL) -> CodexRateLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lastSeen: CodexRateLimits? = nil
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let any = try? JSONSerialization.jsonObject(with: lineData) else { continue }
            guard let event = any as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let rate = payload["rate_limits"] as? [String: Any] else { continue }
            if let parsed = CodexRateLimits.from(rate) {
                lastSeen = parsed
            }
        }
        return lastSeen
    }

    /// Builds a `UsageSnapshot` from the primary (5h) rate-limit bucket.
    /// Plan-type and secondary (weekly) are surfaced through the display
    /// fields so the popover row can show "primary 30% • plus" with the
    /// real plan tier from the server.
    private static func snapshot(from limits: CodexRateLimits, now: Date) -> UsageSnapshot {
        let fraction = max(0, min(1.0, limits.primaryUsedPercent / 100.0))
        let usedInt = Int(limits.primaryUsedPercent.rounded())
        let display = UsageDisplay(
            used: "\(usedInt)%",
            total: "100%",
            unit: limits.planType ?? "codex"
        )
        return UsageSnapshot(
            service: .codex,
            readAt: now,
            window: .sessionWindow5h,
            usedFraction: fraction,
            resetAt: limits.primaryResetsAt,
            usageDisplay: display
        )
    }
}

// MARK: - Codex rate_limits schema

/// Mirror of the `payload.rate_limits` object Codex CLI persists into every
/// rollout JSONL event. Verified 2026-06-21 against the real codex install.
public struct CodexRateLimits: Equatable {
    public let primaryUsedPercent: Double
    public let primaryWindowMinutes: Int
    public let primaryResetsAt: Date
    public let secondaryUsedPercent: Double
    public let secondaryWindowMinutes: Int
    public let secondaryResetsAt: Date
    public let planType: String?

    /// Tolerant decode — Codex may add new buckets later (e.g. `tertiary`,
    /// `credits`). The two we need (`primary`, `secondary`) are required;
    /// anything else is ignored.
    static func from(_ dict: [String: Any]) -> CodexRateLimits? {
        guard let primary = dict["primary"] as? [String: Any],
              let primaryPct = (primary["used_percent"] as? NSNumber)?.doubleValue,
              let primaryWindow = (primary["window_minutes"] as? NSNumber)?.intValue,
              let primaryResetsAt = (primary["resets_at"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let secondary = (dict["secondary"] as? [String: Any]) ?? [:]
        let secondaryPct = (secondary["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let secondaryWindow = (secondary["window_minutes"] as? NSNumber)?.intValue ?? 0
        let secondaryResetsAt = (secondary["resets_at"] as? NSNumber)?.doubleValue ?? primaryResetsAt
        return CodexRateLimits(
            primaryUsedPercent: primaryPct,
            primaryWindowMinutes: primaryWindow,
            primaryResetsAt: Date(timeIntervalSince1970: primaryResetsAt),
            secondaryUsedPercent: secondaryPct,
            secondaryWindowMinutes: secondaryWindow,
            secondaryResetsAt: Date(timeIntervalSince1970: secondaryResetsAt),
            planType: dict["plan_type"] as? String
        )
    }
}

