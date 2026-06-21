import Foundation

/// Reads Claude Code usage from `~/.claude/projects/` and produces a
/// `UsageSnapshot` representing the current 5h session window.
///
/// Architecture:
/// ```
///   ┌───────────────────────────────────────────────────────────┐
///   │ ClaudeReader.read(now:)                                   │
///   │   1. enumerate ~/.claude/projects/<*>/*.jsonl             │
///   │   2. stat each → URL → mtime                              │
///   │   3. JSONLFileCache: re-parse changed, keep unchanged     │
///   │   4. prune deleted entries                                │
///   │   5. detect active 5h session from merged records         │
///   │   6. accumulate totals → emit UsageSnapshot               │
///   └───────────────────────────────────────────────────────────┘
/// ```
///
/// Outputs a `UsageSnapshot` whose `usedFraction` reports **elapsed time** in
/// the current 5h session window (not token budget). The token-budget
/// interpretation requires knowing the user's plan max, which Claude doesn't
/// expose in the JSONL. Time-remaining is honest and matches the wedge anchor
/// ("how much time before reset"). v1.1 can add per-plan token estimation.
public final class ClaudeReader {

    /// 5h session window length.
    public static let sessionWindow: TimeInterval = 5 * 60 * 60

    public struct Result: Equatable, Sendable {
        public let snapshot: UsageSnapshot?
        public let sessionTotals: ClaudeUsageTotals
        /// First event in the active session window, or nil if no recent activity.
        public let activeSessionStart: Date?
        /// Files seen in this scan. Used by diagnostics + tests.
        public let filesScanned: Int
        /// Files re-parsed this scan (mtime had changed).
        public let filesReparsed: Int
        public let totalRecordCount: Int
        public let totalMalformedLines: Int
    }

    public let projectsDirectory: URL
    public let cache: JSONLFileCache
    public let parser: ClaudeJSONLParser
    private let fileManager: FileManager

    public init(
        projectsDirectory: URL,
        cache: JSONLFileCache = JSONLFileCache(),
        parser: ClaudeJSONLParser = ClaudeJSONLParser(),
        fileManager: FileManager = .default
    ) {
        self.projectsDirectory = projectsDirectory
        self.cache = cache
        self.parser = parser
        self.fileManager = fileManager
    }

    /// Convenience initializer using the canonical `~/.claude/projects/` path.
    /// Returns `nil` if the directory cannot be located (no home dir, etc).
    public static func userDefault() -> ClaudeReader? {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return nil }
        let url = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        return ClaudeReader(projectsDirectory: url)
    }

    // MARK: - Read

    /// Scan the projects directory, reconcile the cache, and produce the
    /// current usage snapshot.
    ///
    /// Returns a `Result` with both the snapshot (suitable for `StateStore`
    /// publication) and diagnostic counts (files scanned / reparsed / records).
    public func read(now: Date = Date()) throws -> Result {
        let (liveFiles, filesReparsed) = try stateAndReparse()

        // Prune cache entries for deleted files.
        cache.prune(livePaths: Set(liveFiles))

        // Merge all records and sort by timestamp.
        let allRecords = cache.allRecords.sorted { $0.timestamp < $1.timestamp }

        // Find the active 5h session.
        let activeSession = findActiveSession(records: allRecords, now: now)
        let sessionTotals: ClaudeUsageTotals
        let snapshot: UsageSnapshot?
        if let session = activeSession {
            let inSession = allRecords.filter {
                $0.timestamp >= session.start && $0.timestamp <= session.end
            }
            sessionTotals = ClaudeUsageTotals.sum(inSession)
            snapshot = makeSnapshot(session: session, totals: sessionTotals, now: now)
        } else {
            sessionTotals = ClaudeUsageTotals()
            snapshot = nil
        }

        return Result(
            snapshot: snapshot,
            sessionTotals: sessionTotals,
            activeSessionStart: activeSession?.start,
            filesScanned: liveFiles.count,
            filesReparsed: filesReparsed,
            totalRecordCount: allRecords.count,
            totalMalformedLines: cache.totalMalformedLines
        )
    }

    // MARK: - File enumeration

    /// Enumerate every `*.jsonl` under `projectsDirectory/<project>/`, and
    /// (re)parse the files whose mtime advanced since the last scan.
    /// Returns the live file set + count of files re-parsed.
    private func stateAndReparse() throws -> (liveFiles: [URL], filesReparsed: Int) {
        guard fileManager.fileExists(atPath: projectsDirectory.path) else {
            return ([], 0)
        }
        var liveFiles: [URL] = []
        var filesReparsed = 0

        // Top-level enumerate project directories.
        let topEntries = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for projectDir in topEntries {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) ?? false
            guard isDir else { continue }

            // Each project directory contains <session-id>.jsonl files.
            let inner = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in inner where fileURL.pathExtension == "jsonl" {
                liveFiles.append(fileURL)
                let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                guard let mtime = attrs?.contentModificationDate else { continue }
                let cached = cache[fileURL]
                if let cached, cached.mtime == mtime {
                    continue
                }
                // mtime advanced (or no cache entry) → reparse.
                if let data = try? Data(contentsOf: fileURL) {
                    let result = parser.parse(data: data)
                    cache.upsert(url: fileURL, mtime: mtime, parse: result)
                    filesReparsed += 1
                }
            }
        }
        return (liveFiles, filesReparsed)
    }

    // MARK: - Session window

    public struct Session: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public init(start: Date) {
            self.start = start
            self.end = start.addingTimeInterval(ClaudeReader.sessionWindow)
        }
    }

    /// Locate the active 5h session given the full sorted record list.
    ///
    /// Algorithm:
    /// 1. If no records, no session.
    /// 2. Walk backward from the most recent record. Group records into the
    ///    same session as long as consecutive timestamps are within 5h of one
    ///    another.
    /// 3. The session "starts" at the earliest record of that contiguous block.
    /// 4. The session is "active" if `now` is within `start + 5h`.
    /// 5. Otherwise, return nil (the most recent activity has already aged
    ///    out — show neutral / awaiting-setup).
    func findActiveSession(records: [ClaudeUsageRecord], now: Date) -> Session? {
        guard !records.isEmpty else { return nil }

        // Claude's actual billing model (verified 2026-06-21 against real
        // user data): a 5h window OPENS at the first message after any prior
        // window has expired. All messages within [windowStart, windowStart+5h]
        // count toward that window. Past windowStart+5h, the NEXT message
        // opens a fresh window with its own fixed start.
        //
        // Earlier algorithm (broken): walked backward and absorbed any event
        // within 5h of a moving session start. That treated "I used Claude
        // this morning, then again 3h later this afternoon" as ONE 5h session
        // anchored to the morning, blowing usedFraction up to 91% when the
        // real fixed-window-from-afternoon-first-message was at 20-40%.
        //
        // Correct algorithm: sort events ascending, walk forward, and roll
        // the window start every time an event falls past the current
        // window's end. The final windowStart is the most-recent window.
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        var windowStart = sorted[0].timestamp
        for record in sorted.dropFirst() {
            let windowEnd = windowStart.addingTimeInterval(Self.sessionWindow)
            if record.timestamp >= windowEnd {
                windowStart = record.timestamp
            }
        }

        let session = Session(start: windowStart)
        // Active only if now is within the 5h window from start.
        guard now <= session.end else { return nil }
        return session
    }

    private func makeSnapshot(
        session: Session,
        totals: ClaudeUsageTotals,
        now: Date
    ) -> UsageSnapshot {
        // usedFraction = elapsed / 5h session window (vendor-aligned semantics).
        let totalSeconds = Self.sessionWindow
        let elapsed = max(0, min(totalSeconds, now.timeIntervalSince(session.start)))
        let fraction = elapsed / totalSeconds
        return UsageSnapshot(
            service: .claude,
            readAt: now,
            window: .sessionWindow5h,
            usedFraction: fraction,
            resetAt: session.end,
            usageDisplay: nil
        )
    }
}
