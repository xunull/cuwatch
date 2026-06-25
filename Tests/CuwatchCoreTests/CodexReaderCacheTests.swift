import XCTest
@testable import CuwatchCore

/// Tests for the mtime+size cache added to `CodexReader` in plan #3.
///
/// The cache short-circuits 30s-cadence re-reads of identical rollout
/// JSONL files. With `~/.codex/sessions` accumulating 132 files / 752 MB
/// in the wild (observed 2026-06-25), the unpatched reader was burning
/// ~150MB of IO per poll. After this fix, steady-state hit rate is >95%
/// (only the actively-growing rollout file misses).
///
/// See `docs/popover-deadlock-fix-plan.md` § #3.
final class CodexReaderCacheTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-codex-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        tempHome = nil
        super.tearDown()
    }

    // MARK: - Helpers (mirror CodexReaderTests fixtures)

    private func makeCodexDir() throws {
        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    }

    private func writeAuthJSON() throws {
        try makeCodexDir()
        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try Data("{}".utf8).write(to: codexDir.appendingPathComponent("auth.json"))
    }

    /// Builds the same `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` path
    /// shape codex CLI uses, writes a single rate_limits event into it,
    /// and returns the URL.
    @discardableResult
    private func writeRolloutWithRateLimits(sessionStart: Date,
                                            primaryPct: Double,
                                            primaryResetsAt: Date,
                                            uuidSuffix: String = "019e8cbf-7fcd-74e0-ab17-73b8b34c1128") throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let comp = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: sessionStart
        )
        let y = String(format: "%04d", comp.year!)
        let m = String(format: "%02d", comp.month!)
        let d = String(format: "%02d", comp.day!)
        let h = String(format: "%02d", comp.hour!)
        let mi = String(format: "%02d", comp.minute!)
        let s = String(format: "%02d", comp.second!)
        let dayDir = tempHome
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent(d, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let name = "rollout-\(y)-\(m)-\(d)T\(h)-\(mi)-\(s)-\(uuidSuffix).jsonl"
        let file = dayDir.appendingPathComponent(name)
        let line = """
        {"type":"chat","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primaryPct),"window_minutes":300,"resets_at":\(Int(primaryResetsAt.timeIntervalSince1970))},"secondary":{"used_percent":47.0,"window_minutes":10080,"resets_at":\(Int(primaryResetsAt.timeIntervalSince1970))},"plan_type":"plus"}}}
        """
        try Data(line.utf8).write(to: file)
        return file
    }

    // MARK: - #3 cache tests

    /// The headline acceptance: with mtime+size unchanged, the second read
    /// MUST not re-open the file. `fullReadCount` is the public proof —
    /// if it stays at 1 after two `read()` calls, the cache short-circuited.
    func testCacheHitSkipsFileRead() throws {
        try writeAuthJSON()
        let now = Date()
        try writeRolloutWithRateLimits(
            sessionStart: now.addingTimeInterval(-30 * 60),
            primaryPct: 30.0,
            primaryResetsAt: now.addingTimeInterval(3 * 3600)
        )

        let reader = CodexReader(homeDirectory: tempHome)

        let first = reader.read(now: now)
        XCTAssertEqual(first.snapshot?.usedFraction ?? 0, 0.30, accuracy: 0.001)
        XCTAssertEqual(reader.fullReadCount, 1, "first read should miss the cache and read the file")
        XCTAssertEqual(reader.cacheCount, 1, "cache should hold one entry")

        let second = reader.read(now: now)
        XCTAssertEqual(second.snapshot?.usedFraction ?? 0, 0.30, accuracy: 0.001)
        XCTAssertEqual(reader.fullReadCount, 1,
                       "second read should HIT the cache — fullReadCount must not increment")
        XCTAssertEqual(reader.cacheCount, 1, "cache should still hold the same single entry")
    }

    /// When a file's mtime changes (codex CLI wrote a new event), the cache
    /// entry MUST invalidate and the reader MUST re-parse to surface the
    /// fresh rate_limits.
    func testCacheInvalidationOnMtimeChange() throws {
        try writeAuthJSON()
        let now = Date()
        let file = try writeRolloutWithRateLimits(
            sessionStart: now.addingTimeInterval(-60 * 60),
            primaryPct: 25.0,
            primaryResetsAt: now.addingTimeInterval(3 * 3600)
        )

        let reader = CodexReader(homeDirectory: tempHome)

        let first = reader.read(now: now)
        XCTAssertEqual(first.snapshot?.usedFraction ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(reader.fullReadCount, 1)

        // Rewrite the file with a higher used_percent. New content = new
        // size + new mtime (filesystem updates both on overwrite).
        let newLine = """
        {"type":"chat","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":78.0,"window_minutes":300,"resets_at":\(Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970))},"secondary":{"used_percent":47.0,"window_minutes":10080,"resets_at":\(Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970))},"plan_type":"plus"}}}
        """
        // Belt-and-suspenders: bump mtime forward in case the rewrite lands
        // in the same second as the original write.
        try Data(newLine.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: file.path
        )

        let second = reader.read(now: now)
        XCTAssertEqual(second.snapshot?.usedFraction ?? 0, 0.78, accuracy: 0.001,
                       "after file rewrite, reader must surface FRESH rate_limits")
        XCTAssertEqual(reader.fullReadCount, 2,
                       "mtime+size changed → cache miss → fullReadCount increments")
        XCTAssertEqual(reader.cacheCount, 1, "cache holds the updated entry")
    }

    /// File deletion (codex log rotation, user cleanup) MUST evict the cache
    /// entry. Subsequent read returns nil (or whatever the next candidate
    /// yields), never a crash and never a leaked stale entry.
    func testCacheHandlesDeletedFile() throws {
        try writeAuthJSON()
        let now = Date()
        let file = try writeRolloutWithRateLimits(
            sessionStart: now.addingTimeInterval(-45 * 60),
            primaryPct: 55.0,
            primaryResetsAt: now.addingTimeInterval(3 * 3600)
        )

        let reader = CodexReader(homeDirectory: tempHome)

        let first = reader.read(now: now)
        XCTAssertEqual(first.snapshot?.usedFraction ?? 0, 0.55, accuracy: 0.001)
        XCTAssertEqual(reader.cacheCount, 1)

        // Delete the file. Next poll candidates enumeration won't include
        // it, but if it DID slip through (race between enumeration and
        // delete), the cache lookup's `attributesOfItem` would throw and
        // the catch branch must evict the entry.
        try FileManager.default.removeItem(at: file)

        // Directly exercise the cache-aware path with the now-missing URL to
        // simulate the race: cache has an entry, file is gone.
        let stale = reader.cachedLastRateLimits(in: file)
        XCTAssertNil(stale, "deleted-file path must return nil, not crash")
        XCTAssertEqual(reader.cacheCount, 0,
                       "deleted file's cache entry must be evicted")

        // A full read() against the empty sessions tree returns the time
        // proxy fallback (no rate_limits surface) — verify no crash, no
        // leaked cache entries.
        let second = reader.read(now: now)
        XCTAssertNil(second.snapshot)
        XCTAssertEqual(reader.cacheCount, 0)
    }
}
