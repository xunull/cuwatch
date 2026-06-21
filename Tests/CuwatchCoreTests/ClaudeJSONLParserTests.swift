import XCTest
@testable import CuwatchCore

final class ClaudeJSONLParserTests: XCTestCase {

    private let parser = ClaudeJSONLParser()

    private let validAssistantLine = """
        {"type":"assistant","timestamp":"2026-06-13T10:00:05Z","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1200,"output_tokens":350,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000}}}
        """

    func testParsesValidAssistantEvent() {
        let result = parser.parse(text: validAssistantLine)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.malformedLines, 0)
        XCTAssertEqual(result.totalLines, 1)
        let r = result.records[0]
        XCTAssertEqual(r.model, "claude-opus-4-7")
        XCTAssertEqual(r.inputTokens, 1200)
        XCTAssertEqual(r.outputTokens, 350)
        XCTAssertEqual(r.cacheReadInputTokens, 5000)
        XCTAssertEqual(r.totalInputTokens, 6200) // 1200 + 0 + 5000
    }

    func testSkipsUserEvents() {
        let mixed = """
            {"type":"user","timestamp":"2026-06-13T10:00:00Z","message":{}}
            \(validAssistantLine)
            """
        let result = parser.parse(text: mixed)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.totalLines, 1, "User events shouldn't count as malformed")
        XCTAssertEqual(result.malformedLines, 0)
    }

    func testCountsCorruptLinesAsMalformed() {
        let text = """
            \(validAssistantLine)
            {"this is not": "valid JSON
            \(validAssistantLine)
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.malformedLines, 1)
        XCTAssertEqual(result.totalLines, 3)
    }

    func testIgnoresEmptyAndWhitespaceLines() {
        let text = """
            \(validAssistantLine)

               \t
            \(validAssistantLine)
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.malformedLines, 0)
        XCTAssertEqual(result.totalLines, 2)
    }

    func testCountsAssistantEventWithoutUsageAsMalformed() {
        let text = """
            {"type":"assistant","timestamp":"2026-06-13T10:00:00Z","message":{"model":"claude-opus-4-7"}}
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.malformedLines, 1)
    }

    func testHandlesMissingTimestamp() {
        let text = """
            {"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":100,"output_tokens":50}}}
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.malformedLines, 1)
    }

    func testHandlesUnknownModelByPreservingID() {
        let text = """
            {"type":"assistant","timestamp":"2026-06-13T10:00:00Z","message":{"model":"some-future-model","usage":{"input_tokens":100,"output_tokens":50}}}
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 1)
        // Model id is preserved verbatim — Pricing.cost handles unknown_model fallback.
        XCTAssertEqual(result.records[0].model, "some-future-model")
        // Cost should be nil for unknown model.
        XCTAssertNil(result.records[0].costUSD)
    }

    func testHandlesMissingModel() {
        let text = """
            {"type":"assistant","timestamp":"2026-06-13T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":50}}}
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].model, "unknown_model")
        XCTAssertNil(result.records[0].costUSD)
    }

    func testParsesFractionalSecondsTimestamp() {
        let text = """
            {"type":"assistant","timestamp":"2026-06-13T10:00:00.123Z","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":1}}}
            """
        let result = parser.parse(text: text)
        XCTAssertEqual(result.records.count, 1)
        let expected = ISO8601DateFormatter().date(from: "2026-06-13T10:00:00Z")!
        XCTAssertEqual(result.records[0].timestamp.timeIntervalSince(expected), 0.123, accuracy: 0.001)
    }

    func testEmptyDataReturnsEmpty() {
        XCTAssertTrue(parser.parse(text: "").records.isEmpty)
        XCTAssertTrue(parser.parse(data: Data()).records.isEmpty)
    }

    func testHandlesNonUtf8Data() {
        // Invalid UTF-8 sequence — should return empty result, never crash.
        let data = Data([0xFF, 0xFE, 0x00, 0xC0])
        let result = parser.parse(data: data)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testMalformedFractionComputesCorrectly() {
        let result = ClaudeJSONLParser.ParseResult(records: [], totalLines: 4, malformedLines: 1)
        XCTAssertEqual(result.malformedFraction, 0.25, accuracy: 0.0001)

        let empty = ClaudeJSONLParser.ParseResult(records: [], totalLines: 0, malformedLines: 0)
        XCTAssertEqual(empty.malformedFraction, 0)
    }
}
