import XCTest
@testable import CuwatchCore

final class JSONLFileCacheTests: XCTestCase {

    private func record(at offset: TimeInterval = 0, input: Int = 100) -> ClaudeUsageRecord {
        ClaudeUsageRecord(
            timestamp: Date().addingTimeInterval(offset),
            model: "claude-opus-4-7",
            inputTokens: input, outputTokens: 50
        )
    }

    private func parseResult(_ records: [ClaudeUsageRecord], malformed: Int = 0) -> ClaudeJSONLParser.ParseResult {
        ClaudeJSONLParser.ParseResult(records: records, totalLines: records.count + malformed, malformedLines: malformed)
    }

    private let aURL = URL(fileURLWithPath: "/tmp/cuwatch-test/a.jsonl")
    private let bURL = URL(fileURLWithPath: "/tmp/cuwatch-test/b.jsonl")

    func testEmptyCache() {
        let cache = JSONLFileCache()
        XCTAssertEqual(cache.fileCount, 0)
        XCTAssertTrue(cache.allRecords.isEmpty)
        XCTAssertEqual(cache.totalMalformedLines, 0)
        XCTAssertNil(cache[aURL])
    }

    func testUpsertAndLookup() {
        let cache = JSONLFileCache()
        let m = Date()
        cache.upsert(url: aURL, mtime: m, parse: parseResult([record(at: -3600), record(at: -1800)]))
        XCTAssertEqual(cache.fileCount, 1)
        XCTAssertEqual(cache[aURL]?.mtime, m)
        XCTAssertEqual(cache[aURL]?.records.count, 2)
        XCTAssertEqual(cache.allRecords.count, 2)
    }

    func testUpsertReplacesPriorEntry() {
        let cache = JSONLFileCache()
        let m1 = Date(timeIntervalSinceNow: -100)
        let m2 = Date()
        cache.upsert(url: aURL, mtime: m1, parse: parseResult([record(at: -3600)]))
        cache.upsert(url: aURL, mtime: m2, parse: parseResult([record(at: -1800), record(at: -900)]))
        XCTAssertEqual(cache.fileCount, 1)
        XCTAssertEqual(cache[aURL]?.mtime, m2)
        XCTAssertEqual(cache[aURL]?.records.count, 2)
    }

    func testRemove() {
        let cache = JSONLFileCache()
        cache.upsert(url: aURL, mtime: Date(), parse: parseResult([record()]))
        cache.upsert(url: bURL, mtime: Date(), parse: parseResult([record()]))
        cache.remove(url: aURL)
        XCTAssertEqual(cache.fileCount, 1)
        XCTAssertNil(cache[aURL])
        XCTAssertNotNil(cache[bURL])
    }

    func testPruneRemovesDeadEntries() {
        let cache = JSONLFileCache()
        cache.upsert(url: aURL, mtime: Date(), parse: parseResult([record()]))
        cache.upsert(url: bURL, mtime: Date(), parse: parseResult([record()]))
        // Only `aURL` is alive on disk.
        let removed = cache.prune(livePaths: [aURL])
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(cache.fileCount, 1)
        XCTAssertNotNil(cache[aURL])
        XCTAssertNil(cache[bURL])
    }

    func testPruneWithEmptyLiveSetClearsAll() {
        let cache = JSONLFileCache()
        cache.upsert(url: aURL, mtime: Date(), parse: parseResult([record()]))
        cache.upsert(url: bURL, mtime: Date(), parse: parseResult([record()]))
        let removed = cache.prune(livePaths: Set<URL>())
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(cache.fileCount, 0)
    }

    func testMalformedCountsAccumulate() {
        let cache = JSONLFileCache()
        cache.upsert(url: aURL, mtime: Date(), parse: parseResult([record()], malformed: 3))
        cache.upsert(url: bURL, mtime: Date(), parse: parseResult([record()], malformed: 1))
        XCTAssertEqual(cache.totalMalformedLines, 4)
        XCTAssertEqual(cache.totalLineCount, 6) // 1+3 + 1+1 lines total
    }

    func testClearDropsEverything() {
        let cache = JSONLFileCache()
        cache.upsert(url: aURL, mtime: Date(), parse: parseResult([record()]))
        cache.upsert(url: bURL, mtime: Date(), parse: parseResult([record()]))
        cache.clear()
        XCTAssertEqual(cache.fileCount, 0)
        XCTAssertTrue(cache.allRecords.isEmpty)
    }
}
