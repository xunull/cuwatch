import Foundation

/// Canonical pricing for the models cuwatch parses.
///
/// Update cadence: ~6 months, manual. Source URLs in the model entries.
/// Unknown model IDs fall back to `unknownModel`, where tokens are counted but cost is nil.
///
/// Pricing is in USD per million tokens unless noted.
public enum Pricing {

    /// Look up pricing for a model id seen in a usage record.
    public static func lookup(modelID: String) -> ModelPricing {
        if let exact = byID[modelID] {
            return exact
        }
        // Family prefix fallback: a v1.x model still gets the v1 pricing entry.
        for (prefix, pricing) in byPrefix where modelID.hasPrefix(prefix) {
            return pricing
        }
        return unknownModel
    }

    /// Sentinel used when we count tokens but don't know the price.
    public static let unknownModel = ModelPricing(
        modelID: "unknown_model",
        family: .unknown,
        inputPerMillion: nil,
        cachedInputPerMillion: nil,
        outputPerMillion: nil,
        sourceURL: nil,
        lastVerifiedDate: nil
    )

    /// Exact-match table.
    static let byID: [String: ModelPricing] = {
        var dict: [String: ModelPricing] = [:]
        for entry in allEntries {
            dict[entry.modelID] = entry
        }
        return dict
    }()

    /// Family-prefix fallback table. Sorted longest-first to prefer the most specific match.
    static let byPrefix: [(String, ModelPricing)] = {
        let pairs = familyDefaults.sorted { $0.0.count > $1.0.count }
        return pairs
    }()

    /// All known concrete model IDs.
    static let allEntries: [ModelPricing] = [
        // Anthropic — Claude Opus 4.x (Plan API + Claude Code).
        // Source: https://www.anthropic.com/pricing (token tier as of 2026-06).
        ModelPricing(
            modelID: "claude-opus-4-7",
            family: .claudeOpus4,
            inputPerMillion: 15.00,
            cachedInputPerMillion: 1.50,
            outputPerMillion: 75.00,
            sourceURL: "https://www.anthropic.com/pricing",
            lastVerifiedDate: "2026-06-13"
        ),
        ModelPricing(
            modelID: "claude-opus-4-6",
            family: .claudeOpus4,
            inputPerMillion: 15.00,
            cachedInputPerMillion: 1.50,
            outputPerMillion: 75.00,
            sourceURL: "https://www.anthropic.com/pricing",
            lastVerifiedDate: "2026-06-13"
        ),
        ModelPricing(
            modelID: "claude-sonnet-4-6",
            family: .claudeSonnet4,
            inputPerMillion: 3.00,
            cachedInputPerMillion: 0.30,
            outputPerMillion: 15.00,
            sourceURL: "https://www.anthropic.com/pricing",
            lastVerifiedDate: "2026-06-13"
        ),
        ModelPricing(
            modelID: "claude-haiku-4-5",
            family: .claudeHaiku4,
            inputPerMillion: 1.00,
            cachedInputPerMillion: 0.10,
            outputPerMillion: 5.00,
            sourceURL: "https://www.anthropic.com/pricing",
            lastVerifiedDate: "2026-06-13"
        ),

        // OpenAI Codex (priced per token after the 2026-04-02 update).
        // For Codex CLI on ChatGPT Plus/Pro, the user doesn't see per-token cost — but cuwatch
        // tracks token counts on a best-effort basis when ~/.codex/ exposes them.
        // Source: https://help.openai.com/en/articles/20001106-codex-rate-card
        ModelPricing(
            modelID: "gpt-5-codex",
            family: .openaiCodex,
            inputPerMillion: 1.25,
            cachedInputPerMillion: 0.125,
            outputPerMillion: 10.00,
            sourceURL: "https://help.openai.com/en/articles/20001106-codex-rate-card",
            lastVerifiedDate: "2026-06-13"
        ),

        // Minimax M2.5 — usage drawn from Token Plan.
        // Source: https://pricepertoken.com/pricing-page/provider/minimax
        // Quoted in CNY in console; converted here at ~7 CNY/USD as approximation.
        ModelPricing(
            modelID: "minimax-m2-5",
            family: .minimax,
            inputPerMillion: 0.43,
            cachedInputPerMillion: nil,
            outputPerMillion: 1.72,
            sourceURL: "https://pricepertoken.com/pricing-page/provider/minimax",
            lastVerifiedDate: "2026-06-13"
        ),
    ]

    /// Family-prefix fallback — used when a new model id appears with a known family stem.
    static let familyDefaults: [(String, ModelPricing)] = [
        ("claude-opus-4", allEntries.first(where: { $0.modelID == "claude-opus-4-7" })!),
        ("claude-opus", allEntries.first(where: { $0.modelID == "claude-opus-4-7" })!),
        ("claude-sonnet-4", allEntries.first(where: { $0.modelID == "claude-sonnet-4-6" })!),
        ("claude-sonnet", allEntries.first(where: { $0.modelID == "claude-sonnet-4-6" })!),
        ("claude-haiku-4", allEntries.first(where: { $0.modelID == "claude-haiku-4-5" })!),
        ("claude-haiku", allEntries.first(where: { $0.modelID == "claude-haiku-4-5" })!),
        ("gpt-5-codex", allEntries.first(where: { $0.modelID == "gpt-5-codex" })!),
        ("minimax-m2", allEntries.first(where: { $0.modelID == "minimax-m2-5" })!),
        ("minimax-", allEntries.first(where: { $0.modelID == "minimax-m2-5" })!),
    ]

    /// Compute USD cost for a token usage tuple, or nil if pricing is unknown.
    public static func cost(
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0
    ) -> Double? {
        let entry = lookup(modelID: modelID)
        guard let inP = entry.inputPerMillion,
              let outP = entry.outputPerMillion
        else { return nil }
        let cachedP = entry.cachedInputPerMillion ?? inP
        let inputCost = Double(inputTokens - cachedInputTokens) * (inP / 1_000_000)
        let cachedCost = Double(cachedInputTokens) * (cachedP / 1_000_000)
        let outputCost = Double(outputTokens) * (outP / 1_000_000)
        return inputCost + cachedCost + outputCost
    }
}

/// Pricing entry for a single model id.
public struct ModelPricing: Equatable, Sendable {
    public let modelID: String
    public let family: ModelFamily
    /// USD per million input tokens, or nil if unknown.
    public let inputPerMillion: Double?
    /// USD per million cached-input tokens, or nil if the model doesn't offer prompt caching.
    public let cachedInputPerMillion: Double?
    /// USD per million output tokens, or nil if unknown.
    public let outputPerMillion: Double?
    public let sourceURL: String?
    public let lastVerifiedDate: String?

    public var isKnown: Bool {
        family != .unknown && inputPerMillion != nil
    }
}

public enum ModelFamily: String, Equatable, Sendable {
    case claudeOpus4
    case claudeSonnet4
    case claudeHaiku4
    case openaiCodex
    case minimax
    case unknown
}
