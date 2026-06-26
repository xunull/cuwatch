import Foundation
import SQLite3

/// Aggregated historical statistics for the Codex Logbook panel.
///
/// All values reflect activity on **this Mac, this OpenAI account, across both
/// `codex` CLI and Codex.app desktop client**. They are NOT cross-device
/// aggregates — Codex.app's UI shows cross-device numbers via OpenAI's
/// private API, and those will not match these.
///
/// See `docs/codex-logbook-design.md` for the full design context including
/// the 2026-06-26 "meter → meter + logbook" anchor evolution.
public struct CodexLogbook: Equatable, Sendable {
    /// Sum of `tokens_used` across every thread row in the SQLite DB.
    public let cumulativeTokens: Int64

    /// Max `tokens_used` for any single thread row.
    public let peakTokensSingleThread: Int64

    /// Distinct calendar days (local time) on which at least one thread was
    /// created. Subset of `totalCalendarDays`.
    public let activeDays: Int

    /// Total calendar days from the first activity date to today, inclusive.
    /// Provides the denominator for the "57 / 63" form.
    public let totalCalendarDays: Int

    /// Earliest calendar date of any thread creation (local time). Used to
    /// label the "since <date>" caption.
    public let firstActiveDate: Date?

    /// Current consecutive-active-days streak ending at today (inclusive).
    /// Returns 0 if today has no activity yet — matches Codex.app's
    /// strict definition where a calendar day rollover without activity
    /// resets the current streak to zero.
    public let currentStreakDays: Int

    /// Longest run of consecutive active calendar days seen historically.
    public let longestStreakDays: Int

    /// Wall-clock time when this aggregation was computed.
    public let computedAt: Date
}

/// Reads aggregated historical stats from Codex's local state SQLite database
/// (`~/.codex/state_5.sqlite`). The DB is shared between codex CLI and
/// Codex.app — both keep `threads.tokens_used` up to date in real time.
///
/// Architecture:
/// ```
///   ┌──────────────────────────────────────────────────────────┐
///   │ CodexLogbookReader.read(now:)                            │
///   │   1. locate state_N.sqlite (highest N) under ~/.codex/   │
///   │      → not present:  return nil                          │
///   │   2. open SQLITE_OPEN_READONLY (safe vs WAL writers)     │
///   │   3. query SUM(tokens_used), MAX(tokens_used)            │
///   │   4. query DISTINCT date(created_at) → [Date]            │
///   │   5. compute streaks (current + longest) in Swift        │
///   │   6. return CodexLogbook value                           │
///   └──────────────────────────────────────────────────────────┘
/// ```
///
/// Read-only opens are safe to call against a DB that codex CLI / Codex.app
/// is actively writing — SQLite WAL mode supports concurrent readers.
public final class CodexLogbookReader {

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

    /// Read the logbook. Returns nil if the DB doesn't exist or contains no
    /// thread rows. Never throws — failures degrade to nil so the caller can
    /// gracefully hide the logbook panel.
    public func read(now: Date = Date()) -> CodexLogbook? {
        guard let dbURL = locateDatabase() else { return nil }

        var dbPtr: OpaquePointer?
        let openResult = sqlite3_open_v2(dbURL.path, &dbPtr, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db = dbPtr else {
            sqlite3_close(dbPtr)
            return nil
        }
        defer { sqlite3_close(db) }

        let (cumulative, peak) = querySumAndMax(db: db)
        let dates = queryDistinctDates(db: db)
        guard !dates.isEmpty else { return nil }

        guard let firstDate = dates.first, let lastDate = dates.last else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: now)
        let firstDay = cal.startOfDay(for: firstDate)
        let lastDay = cal.startOfDay(for: lastDate)

        let totalCalendarDays = (cal.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1
        let activeDays = dates.count
        let longestStreak = Self.longestStreak(in: dates, calendar: cal)
        let currentStreak = Self.currentStreak(in: dates, today: today, calendar: cal)
        _ = lastDay // documentation: lastDay reserved for future "last active" caption

        return CodexLogbook(
            cumulativeTokens: cumulative,
            peakTokensSingleThread: peak,
            activeDays: activeDays,
            totalCalendarDays: totalCalendarDays,
            firstActiveDate: firstDate,
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            computedAt: now
        )
    }

    // MARK: - DB location

    /// Walk `~/.codex/` looking for `state_N.sqlite` files. Pick the highest
    /// N to be forward-compatible: if OpenAI rolls a `state_6.sqlite` we
    /// pick it automatically without a code change.
    ///
    /// Returns nil if `~/.codex/` doesn't exist or contains no state DB.
    /// Visible to tests via the `homeDirectory` injection.
    func locateDatabase() -> URL? {
        let codexDir = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: codexDir,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let candidates: [(URL, Int)] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let stem = name
                .replacingOccurrences(of: "state_", with: "")
                .replacingOccurrences(of: ".sqlite", with: "")
            guard let n = Int(stem) else { return nil }
            return (url, n)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - Queries

    private func querySumAndMax(db: OpaquePointer) -> (Int64, Int64) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COALESCE(SUM(tokens_used), 0), COALESCE(MAX(tokens_used), 0) FROM threads"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    /// Returns distinct calendar dates (local time) on which any thread was
    /// created, sorted ascending. Uses SQLite's `date()` with `'localtime'`
    /// modifier — SQLite uses the same TZ as our process, which is what we
    /// want for "57 active days out of 63 calendar days" style counting.
    private func queryDistinctDates(db: OpaquePointer) -> [Date] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT DISTINCT date(created_at, 'unixepoch', 'localtime') FROM threads ORDER BY 1 ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var dates: [Date] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let str = String(cString: cstr)
            if let date = formatter.date(from: str) {
                dates.append(date)
            }
        }
        return dates
    }

    // MARK: - Streak math

    /// Longest run of consecutive calendar days in `dates`.
    /// Pre: dates sorted ascending and distinct.
    static func longestStreak(in dates: [Date], calendar: Calendar) -> Int {
        guard !dates.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<dates.count {
            let prev = calendar.startOfDay(for: dates[i - 1])
            let curr = calendar.startOfDay(for: dates[i])
            let diff = calendar.dateComponents([.day], from: prev, to: curr).day ?? 0
            if diff == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    /// Current streak ending at today, inclusive.
    /// - If today has activity → count back from today.
    /// - If today has no activity → 0 (strict "calendar day rollover resets"
    ///   convention, matches Codex.app behavior).
    static func currentStreak(in dates: [Date], today: Date, calendar: Calendar) -> Int {
        guard !dates.isEmpty else { return 0 }
        let todayStart = calendar.startOfDay(for: today)
        guard let last = dates.last else { return 0 }
        let lastStart = calendar.startOfDay(for: last)
        let daysSinceLast = calendar.dateComponents([.day], from: lastStart, to: todayStart).day ?? 0
        if daysSinceLast != 0 { return 0 }   // today has no activity yet

        // Today is active. Walk backward counting consecutive days.
        var streak = 1
        for i in stride(from: dates.count - 2, through: 0, by: -1) {
            let next = calendar.startOfDay(for: dates[i + 1])
            let curr = calendar.startOfDay(for: dates[i])
            let diff = calendar.dateComponents([.day], from: curr, to: next).day ?? 0
            if diff == 1 {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }
}
