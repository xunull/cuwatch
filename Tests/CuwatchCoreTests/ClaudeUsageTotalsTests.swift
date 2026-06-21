import XCTest
@testable import CuwatchCore

final class ClaudeUsageTotalsTests: XCTestCase {

    private func record(model: String = "claude-opus-4-7", input: Int = 1000,
                        output: Int = 500, cacheCreate: Int = 0, cacheRead: Int = 0) -> ClaudeUsageRecord {
        ClaudeUsageRecord(
            timestamp: Date(),
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreate,
            cacheReadInputTokens: cacheRead
        )
    }

    func testEmptyTotals() {
        let totals = ClaudeUsageTotals()
        XCTAssertTrue(totals.isEmpty)
        XCTAssertEqual(totals.recordCount, 0)
        XCTAssertEqual(totals.inputTokens, 0)
        XCTAssertEqual(totals.outputTokens, 0)
    }

    func testAddSingleRecord() {
        var t = ClaudeUsageTotals()
        t.add(record(input: 1000, output: 500, cacheRead: 200))
        XCTAssertEqual(t.recordCount, 1)
        XCTAssertEqual(t.inputTokens, 1000)
        XCTAssertEqual(t.outputTokens, 500)
        XCTAssertEqual(t.cacheReadInputTokens, 200)
        XCTAssertEqual(t.totalInputTokens, 1200)
        // Cost should be a positive Double for known model.
        XCTAssertNotNil(t.costUSD)
        XCTAssertGreaterThan(t.costUSD ?? 0, 0)
    }

    func testSumPreservesCostWhenAllKnown() {
        let recs = [
            record(input: 1_000_000, output: 0),
            record(input: 0, output: 1_000_000),
        ]
        let totals = ClaudeUsageTotals.sum(recs)
        // claude-opus-4-7 at 15 in + 75 out per million → $90 total.
        XCTAssertEqual(totals.costUSD ?? 0, 90.0, accuracy: 0.0001)
    }

    func testCostBecomesNilWhenAnyRecordHasUnknownModel() {
        let recs = [
            record(model: "claude-opus-4-7", input: 1000, output: 500),
            record(model: "future-model", input: 1000, output: 500),
        ]
        let totals = ClaudeUsageTotals.sum(recs)
        XCTAssertEqual(totals.recordCount, 2)
        XCTAssertNil(totals.costUSD, "Unknown model should poison the cost sum")
    }

    func testAddTwoRecords() {
        var t = ClaudeUsageTotals()
        t.add(record(input: 1000, output: 500))
        t.add(record(input: 2000, output: 1000))
        XCTAssertEqual(t.recordCount, 2)
        XCTAssertEqual(t.inputTokens, 3000)
        XCTAssertEqual(t.outputTokens, 1500)
    }
}
