import XCTest
@testable import CuwatchCore

final class PricingTests: XCTestCase {

    func testLookupExactMatch() {
        let opus = Pricing.lookup(modelID: "claude-opus-4-7")
        XCTAssertEqual(opus.modelID, "claude-opus-4-7")
        XCTAssertEqual(opus.family, .claudeOpus4)
        XCTAssertEqual(opus.inputPerMillion, 15.00)
        XCTAssertEqual(opus.outputPerMillion, 75.00)
        XCTAssertTrue(opus.isKnown)
    }

    func testLookupFamilyPrefixFallback() {
        // A model id we haven't seen but matching a known family prefix should fall through.
        let future = Pricing.lookup(modelID: "claude-opus-4-99-future")
        XCTAssertEqual(future.family, .claudeOpus4)
        XCTAssertEqual(future.inputPerMillion, 15.00)
    }

    func testLookupUnknownReturnsSentinel() {
        let mystery = Pricing.lookup(modelID: "some-future-model-we-dont-know")
        XCTAssertEqual(mystery.family, .unknown)
        XCTAssertNil(mystery.inputPerMillion)
        XCTAssertFalse(mystery.isKnown)
    }

    func testCostKnownModel() {
        // 1M input tokens + 500k output tokens on claude-opus-4-7.
        // input: 1M * $15/M = $15
        // output: 500k * $75/M = $37.50
        // total: $52.50
        let cost = Pricing.cost(modelID: "claude-opus-4-7", inputTokens: 1_000_000, outputTokens: 500_000)
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost ?? 0, 52.50, accuracy: 0.0001)
    }

    func testCostWithCachedInput() {
        // 1M total input of which 800k cached, 200k fresh.
        // fresh:   200k * $15/M = $3.00
        // cached:  800k * $1.50/M = $1.20
        // total: $4.20 (no output here)
        let cost = Pricing.cost(
            modelID: "claude-opus-4-7",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cachedInputTokens: 800_000
        )
        XCTAssertEqual(cost ?? 0, 4.20, accuracy: 0.0001)
    }

    func testCostUnknownModelReturnsNil() {
        let cost = Pricing.cost(modelID: "i-do-not-exist", inputTokens: 100, outputTokens: 100)
        XCTAssertNil(cost)
    }

    func testAllKnownModelsHaveSourceAndDate() {
        for entry in Pricing.allEntries {
            XCTAssertNotNil(entry.sourceURL, "\(entry.modelID) missing sourceURL")
            XCTAssertNotNil(entry.lastVerifiedDate, "\(entry.modelID) missing lastVerifiedDate")
        }
    }

    func testAllKnownModelsHavePositivePricing() {
        for entry in Pricing.allEntries {
            if let p = entry.inputPerMillion {
                XCTAssertGreaterThan(p, 0)
            }
            if let p = entry.outputPerMillion {
                XCTAssertGreaterThan(p, 0)
            }
        }
    }

    func testOutputIsAlwaysAtLeastAsExpensiveAsInput() {
        // Sanity heuristic: for all current AI providers, output is priced ≥ input.
        for entry in Pricing.allEntries {
            guard let inP = entry.inputPerMillion,
                  let outP = entry.outputPerMillion else { continue }
            XCTAssertGreaterThanOrEqual(outP, inP, "\(entry.modelID) has unusual output ≤ input pricing")
        }
    }
}
