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
            // Spike-pending: when the parser lands, replace this with a real
            // tokens-used + window-start extraction. For now, if we have a
            // session-start time, surface a time-remaining snapshot anyway —
            // it's still useful and matches how Claude reads.
            guard let sessionStart else {
                return Result(snapshot: nil, probe: probe)
            }
            let snapshot = makeTimeBasedSnapshot(sessionStart: sessionStart, now: now)
            return Result(snapshot: snapshot, probe: probe)
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

    /// Spike-pending placeholder: scan `~/.codex/sessions/` for the most
    /// recent session file and return its mtime. Once the spike confirms the
    /// real JSON schema this becomes proper JSON parsing of session-start +
    /// tokens-used.
    private func detectSessionStart() -> Date? {
        // TODO(spike): replace with real session-state parsing once the
        // ~/.codex/sessions/ schema is documented (per /plan-eng-review D2,
        // may study CodexBar source for the read pattern).
        let sessionsDir = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsDir.path) else { return nil }
        let candidates = (try? fileManager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var earliestRecent: Date? = nil
        let cutoff = Date().addingTimeInterval(-Self.sessionWindow)
        for url in candidates {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            guard mtime >= cutoff else { continue }
            if earliestRecent == nil || mtime < earliestRecent! {
                earliestRecent = mtime
            }
        }
        return earliestRecent
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
}

