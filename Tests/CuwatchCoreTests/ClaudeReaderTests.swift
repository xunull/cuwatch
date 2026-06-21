import XCTest
@testable import CuwatchCore

final class ClaudeReaderTests: XCTestCase {

    private var tempDir: URL!
    private var iso: ISO8601DateFormatter!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-reader-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        iso = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeJSONL(project: String, file: String, lines: [String]) throws -> URL {
        let projectDir = tempDir.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("\(file).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func assistantLine(at: Date, model: String = "claude-opus-4-7",
                               input: Int = 1000, output: Int = 500,
                               cacheCreate: Int = 0, cacheRead: Int = 0) -> String {
        let ts = iso.string(from: at)
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_creation_input_tokens\":\(cacheCreate),\"cache_read_input_tokens\":\(cacheRead)}}}"
    }

    private func userLine(at: Date) -> String {
        let ts = iso.string(from: at)
        return "{\"type\":\"user\",\"timestamp\":\"\(ts)\",\"message\":{}}"
    }

    private func setMTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Tests

    func testEmptyDirectoryReturnsNoSnapshot() throws {
        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: Date())
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(result.sessionTotals.isEmpty)
        XCTAssertEqual(result.filesScanned, 0)
        XCTAssertEqual(result.filesReparsed, 0)
    }

    func testMissingDirectoryReturnsNoSnapshot() throws {
        let nonexistent = tempDir.appendingPathComponent("does-not-exist")
        let reader = ClaudeReader(projectsDirectory: nonexistent)
        let result = try reader.read(now: Date())
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.filesScanned, 0)
    }

    func testSingleSessionAccumulatesTokens() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-30 * 60)   // 30 min ago
        let t1 = now.addingTimeInterval(-10 * 60)   // 10 min ago

        _ = try writeJSONL(project: "p1", file: "s1", lines: [
            userLine(at: t0),
            assistantLine(at: t0, input: 1000, output: 500),
            assistantLine(at: t1, input: 2000, output: 700, cacheRead: 5000),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: now)
        XCTAssertNotNil(result.snapshot)
        XCTAssertEqual(result.sessionTotals.recordCount, 2)
        XCTAssertEqual(result.sessionTotals.inputTokens, 3000)
        XCTAssertEqual(result.sessionTotals.outputTokens, 1200)
        XCTAssertEqual(result.sessionTotals.cacheReadInputTokens, 5000)
        XCTAssertNotNil(result.activeSessionStart)
        XCTAssertEqual(result.activeSessionStart!.timeIntervalSince(t0), 0, accuracy: 1.0)
        XCTAssertEqual(result.snapshot?.service, .claude)
        XCTAssertEqual(result.snapshot?.window, .sessionWindow5h)
        // Session started 30 min ago in a 5h window → 10% elapsed = 10% used.
        let expectedUsed = (30.0 * 60) / (5.0 * 3600)
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, expectedUsed, accuracy: 0.01)
    }

    /// Regression test for 2026-06-21 bug. Real-world failure: user ran a
    /// morning session that ended naturally, then started a fresh session in
    /// the afternoon. The OLD backward-adjacent-gap algorithm walked back
    /// across the morning events (because each adjacent pair was within 5h)
    /// and anchored sessionStart to the morning, blowing usedFraction to 91%
    /// when the actual fixed-window usage was around 38%.
    ///
    /// The fix: forward-walk + fixed 5h windows. Events from the morning
    /// session naturally form their own past window; the afternoon's first
    /// event opens a fresh window that's used as the active session.
    func testPreviousSessionDoesNotBleedIntoCurrentWindow() throws {
        let now = Date()
        // Morning chunk opens a window [-8h, -3h]. Last event at -7h sits in it.
        let morning1 = now.addingTimeInterval(-8 * 3600)
        let morning2 = now.addingTimeInterval(-7 * 3600)
        // > 1h gap with NO events from -3h to -1.9h.
        // Afternoon chunk opens a fresh window [-1.9h, +3.1h]. 38% used.
        let afternoon1 = now.addingTimeInterval(-1.9 * 3600)
        let afternoon2 = now.addingTimeInterval(-30 * 60)

        _ = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: morning1, input: 100, output: 50),
            assistantLine(at: morning2, input: 100, output: 50),
            assistantLine(at: afternoon1, input: 100, output: 50),
            assistantLine(at: afternoon2, input: 100, output: 50),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: now)
        XCTAssertNotNil(result.snapshot)
        // After fix: sessionStart pinned to afternoon1 (-1.9h),
        // usedFraction ≈ 1.9 / 5 = 0.38. Before fix this was 0.91.
        XCTAssertEqual(result.snapshot!.usedFraction, 1.9 / 5.0, accuracy: 0.02)
        XCTAssertEqual(result.activeSessionStart!.timeIntervalSince(afternoon1), 0, accuracy: 1.0)
    }

    func testSessionEndsAfter5HoursOfInactivity() throws {
        let now = Date()
        let veryOld = now.addingTimeInterval(-6 * 3600) // 6h ago — outside window

        _ = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: veryOld, input: 1000, output: 500),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: now)
        XCTAssertNil(result.snapshot, "Session is too old to be active")
        XCTAssertEqual(result.sessionTotals.recordCount, 0)
    }

    func testMultipleProjectsMerge() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-20 * 60)
        let t1 = now.addingTimeInterval(-10 * 60)

        _ = try writeJSONL(project: "projA", file: "s1", lines: [
            assistantLine(at: t0, input: 1000, output: 500),
        ])
        _ = try writeJSONL(project: "projB", file: "s2", lines: [
            assistantLine(at: t1, input: 2000, output: 700),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: now)
        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.filesReparsed, 2)
        XCTAssertEqual(result.sessionTotals.recordCount, 2)
        XCTAssertEqual(result.sessionTotals.inputTokens, 3000)
        XCTAssertEqual(result.sessionTotals.outputTokens, 1200)
    }

    func testMtimeCacheSkipsReparseWhenUnchanged() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-30 * 60)
        let url = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: t0, input: 1000, output: 500),
        ])
        // Pin mtime to a stable value.
        let stableMtime = now.addingTimeInterval(-300)
        try setMTime(url, stableMtime)

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let first = try reader.read(now: now)
        XCTAssertEqual(first.filesReparsed, 1)
        XCTAssertEqual(first.sessionTotals.recordCount, 1)

        // Second read — mtime didn't change, expect 0 reparsed.
        let second = try reader.read(now: now)
        XCTAssertEqual(second.filesReparsed, 0, "Same mtime should skip re-parse")
        XCTAssertEqual(second.sessionTotals.recordCount, 1, "Cached records still merged")
    }

    func testMtimeCacheReparsesWhenMtimeAdvances() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-30 * 60)
        let url = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: t0, input: 1000, output: 500),
        ])
        let mtimeOld = now.addingTimeInterval(-600)
        try setMTime(url, mtimeOld)

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let first = try reader.read(now: now)
        XCTAssertEqual(first.filesReparsed, 1)

        // Append another assistant event and advance the mtime.
        let appendT = now.addingTimeInterval(-5 * 60)
        let newLine = assistantLine(at: appendT, input: 3000, output: 1000)
        let fh = try FileHandle(forWritingTo: url)
        fh.seekToEndOfFile()
        fh.write((newLine + "\n").data(using: .utf8)!)
        try fh.close()
        try setMTime(url, now)

        let second = try reader.read(now: now)
        XCTAssertEqual(second.filesReparsed, 1, "mtime advanced → re-parse")
        XCTAssertEqual(second.sessionTotals.recordCount, 2)
        XCTAssertEqual(second.sessionTotals.inputTokens, 4000)
    }

    func testFileDeletionDropsFromCache() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-30 * 60)
        let url = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: t0, input: 1000, output: 500),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        _ = try reader.read(now: now)
        XCTAssertEqual(reader.cache.fileCount, 1)

        try FileManager.default.removeItem(at: url)

        let after = try reader.read(now: now)
        XCTAssertEqual(after.filesScanned, 0)
        XCTAssertEqual(reader.cache.fileCount, 0, "Deleted file should be pruned from cache")
        XCTAssertNil(after.snapshot)
    }

    func testFindActiveSessionEmpty() {
        let reader = ClaudeReader(projectsDirectory: tempDir)
        let session = reader.findActiveSession(records: [], now: Date())
        XCTAssertNil(session)
    }

    func testFindActiveSessionSingleRecord() {
        let reader = ClaudeReader(projectsDirectory: tempDir)
        let now = Date()
        let r = ClaudeUsageRecord(
            timestamp: now.addingTimeInterval(-60), model: "claude-opus-4-7",
            inputTokens: 100, outputTokens: 50
        )
        let session = reader.findActiveSession(records: [r], now: now)
        XCTAssertNotNil(session)
        XCTAssertEqual(session!.start.timeIntervalSince(r.timestamp), 0, accuracy: 0.001)
        XCTAssertEqual(session!.end.timeIntervalSince(r.timestamp), 5 * 3600, accuracy: 0.001)
    }

    func testFindActiveSessionStopsAtGapLargerThan5h() {
        let reader = ClaudeReader(projectsDirectory: tempDir)
        let now = Date()
        // Old session 10h ago, then a new event 1h ago — the older block isn't
        // part of the active session.
        let oldRec = ClaudeUsageRecord(
            timestamp: now.addingTimeInterval(-10 * 3600), model: "claude-opus-4-7",
            inputTokens: 100, outputTokens: 50
        )
        let recentRec = ClaudeUsageRecord(
            timestamp: now.addingTimeInterval(-1 * 3600), model: "claude-opus-4-7",
            inputTokens: 100, outputTokens: 50
        )
        let session = reader.findActiveSession(records: [oldRec, recentRec], now: now)
        XCTAssertNotNil(session)
        XCTAssertEqual(session!.start.timeIntervalSince(recentRec.timestamp), 0, accuracy: 0.001)
    }

    func testFindActiveSessionExtendsThroughClusters() {
        let reader = ClaudeReader(projectsDirectory: tempDir)
        let now = Date()
        // Events all within 5h of each other; session spans from earliest to latest.
        let records = [
            ClaudeUsageRecord(timestamp: now.addingTimeInterval(-3 * 3600), model: "claude-opus-4-7",
                              inputTokens: 100, outputTokens: 50),
            ClaudeUsageRecord(timestamp: now.addingTimeInterval(-2 * 3600), model: "claude-opus-4-7",
                              inputTokens: 100, outputTokens: 50),
            ClaudeUsageRecord(timestamp: now.addingTimeInterval(-1 * 3600), model: "claude-opus-4-7",
                              inputTokens: 100, outputTokens: 50),
        ]
        let session = reader.findActiveSession(records: records, now: now)
        XCTAssertNotNil(session)
        XCTAssertEqual(session!.start.timeIntervalSince(records[0].timestamp), 0, accuracy: 0.001)
        let elapsedFromNow = now.timeIntervalSince(session!.start)
        XCTAssertEqual(elapsedFromNow, 3 * 3600, accuracy: 0.001)
    }

    func testCorruptLinesDoNotBreakReader() throws {
        let now = Date()
        let t0 = now.addingTimeInterval(-30 * 60)
        _ = try writeJSONL(project: "p1", file: "s1", lines: [
            assistantLine(at: t0, input: 1000, output: 500),
            "garbage line that won't parse",
            assistantLine(at: t0.addingTimeInterval(60), input: 200, output: 100),
        ])

        let reader = ClaudeReader(projectsDirectory: tempDir)
        let result = try reader.read(now: now)
        XCTAssertEqual(result.sessionTotals.recordCount, 2)
        XCTAssertEqual(result.totalMalformedLines, 1)
    }
}
