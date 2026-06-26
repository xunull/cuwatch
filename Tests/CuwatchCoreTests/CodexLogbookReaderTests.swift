import XCTest
import SQLite3
@testable import CuwatchCore

/// Tests for `CodexLogbookReader` — aggregated stats panel data source.
/// See `docs/codex-logbook-design.md` for design context.
final class CodexLogbookReaderTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-codex-logbook-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        tempHome = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func codexDir() throws -> URL {
        let dir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create an empty `state_5.sqlite` with the real `threads` schema.
    @discardableResult
    private func createStateDB(version: Int = 5, withSchema: Bool = true) throws -> URL {
        let dir = try codexDir()
        let dbURL = dir.appendingPathComponent("state_\(version).sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: nil)

        if withSchema {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            // Minimal schema — only the columns the reader queries.
            let create = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0
            );
            """
            XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        }
        return dbURL
    }

    /// Insert one thread row at the given Unix epoch + tokens.
    private func insertThread(into dbURL: URL, id: String, createdAt: Date, tokensUsed: Int64) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "INSERT INTO threads (id, created_at, tokens_used) VALUES (?, ?, ?)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(createdAt.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 3, tokensUsed)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var comp = DateComponents()
        comp.year = year; comp.month = month; comp.day = day; comp.hour = hour
        comp.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: comp)!
    }

    // MARK: - Locator

    func testNoCodexDirReturnsNil() {
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        XCTAssertNil(reader.read())
        XCTAssertNil(reader.locateDatabase())
    }

    func testNoStateDBInCodexDirReturnsNil() throws {
        _ = try codexDir()  // create the dir but no DB file
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        XCTAssertNil(reader.locateDatabase())
        XCTAssertNil(reader.read())
    }

    func testPicksHighestVersionedStateDB() throws {
        _ = try createStateDB(version: 3, withSchema: false)
        let v5 = try createStateDB(version: 5, withSchema: false)
        _ = try createStateDB(version: 2, withSchema: false)
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        XCTAssertEqual(reader.locateDatabase()?.lastPathComponent, v5.lastPathComponent)
    }

    func testEmptyThreadsTableReturnsNil() throws {
        _ = try createStateDB()
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        XCTAssertNil(reader.read(), "Empty threads table should hide the logbook entirely")
    }

    // MARK: - Aggregations

    func testCumulativeAndPeakTokens() throws {
        let dbURL = try createStateDB()
        try insertThread(into: dbURL, id: "a", createdAt: date(2026, 6, 1), tokensUsed: 100_000)
        try insertThread(into: dbURL, id: "b", createdAt: date(2026, 6, 2), tokensUsed: 250_000)
        try insertThread(into: dbURL, id: "c", createdAt: date(2026, 6, 3), tokensUsed: 75_000)
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        let book = reader.read(now: date(2026, 6, 3, hour: 18))
        XCTAssertNotNil(book)
        XCTAssertEqual(book?.cumulativeTokens, 425_000)
        XCTAssertEqual(book?.peakTokensSingleThread, 250_000)
    }

    func testActiveDaysAndTotalCalendarDays() throws {
        let dbURL = try createStateDB()
        // 3 active days within a 7-day calendar span
        try insertThread(into: dbURL, id: "a", createdAt: date(2026, 6, 1), tokensUsed: 1)
        try insertThread(into: dbURL, id: "b", createdAt: date(2026, 6, 4), tokensUsed: 1)
        try insertThread(into: dbURL, id: "c", createdAt: date(2026, 6, 7), tokensUsed: 1)
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        let book = reader.read(now: date(2026, 6, 7, hour: 23))
        XCTAssertEqual(book?.activeDays, 3)
        XCTAssertEqual(book?.totalCalendarDays, 7)  // 6-01 → 6-07 inclusive
        XCTAssertNotNil(book?.firstActiveDate)
    }

    func testLongestStreak() throws {
        let dbURL = try createStateDB()
        // Streak pattern: 3 consecutive, gap, 5 consecutive, gap, 2 consecutive
        let runs: [(Int, Int)] = [
            (6, 1), (6, 2), (6, 3),                  // streak 3
            (6, 10), (6, 11), (6, 12), (6, 13), (6, 14),  // streak 5 ← longest
            (6, 20), (6, 21),                         // streak 2
        ]
        for (i, (m, d)) in runs.enumerated() {
            try insertThread(into: dbURL, id: "t\(i)", createdAt: date(2026, m, d), tokensUsed: 1)
        }
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        let book = reader.read(now: date(2026, 6, 25))
        XCTAssertEqual(book?.longestStreakDays, 5)
    }

    func testCurrentStreakWhenTodayIsActive() throws {
        let dbURL = try createStateDB()
        // 4 consecutive days ending today (6-25)
        for d in 22...25 {
            try insertThread(into: dbURL, id: "t\(d)", createdAt: date(2026, 6, d), tokensUsed: 1)
        }
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        let book = reader.read(now: date(2026, 6, 25, hour: 18))
        XCTAssertEqual(book?.currentStreakDays, 4)
    }

    func testCurrentStreakIsZeroWhenTodayHasNoActivity() throws {
        let dbURL = try createStateDB()
        // 4 consecutive days ending yesterday (6-24); today (6-25) no activity
        for d in 21...24 {
            try insertThread(into: dbURL, id: "t\(d)", createdAt: date(2026, 6, d), tokensUsed: 1)
        }
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        let book = reader.read(now: date(2026, 6, 25, hour: 23))
        XCTAssertEqual(book?.currentStreakDays, 0,
                       "Codex.app convention: calendar rollover without activity resets to 0")
        XCTAssertEqual(book?.longestStreakDays, 4,
                       "Longest streak still records the past run of 4")
    }

    // MARK: - Forward compat

    func testReadsFromFutureSchemaVersion() throws {
        // Simulate OpenAI shipping state_6.sqlite
        let dbURL = try createStateDB(version: 6)
        try insertThread(into: dbURL, id: "a", createdAt: date(2026, 6, 25), tokensUsed: 12345)
        let reader = CodexLogbookReader(homeDirectory: tempHome)
        XCTAssertEqual(reader.locateDatabase()?.lastPathComponent, "state_6.sqlite")
        let book = reader.read(now: date(2026, 6, 25, hour: 18))
        XCTAssertEqual(book?.cumulativeTokens, 12345)
    }
}
