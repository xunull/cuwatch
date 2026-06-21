import Foundation

/// A single token-usage data point extracted from a Claude Code JSONL line.
///
/// Each line in `~/.claude/projects/<project>/<session-id>.jsonl` is a JSON
/// event; only assistant events carry `message.usage` and become records.
/// Other lines (user inputs, system messages, errors) are skipped during parse.
public struct ClaudeUsageRecord: Equatable, Hashable, Sendable {

    /// When the event was emitted by the assistant.
    public let timestamp: Date

    /// Model id as reported by the JSONL (e.g. "claude-opus-4-7-20251023").
    public let model: String

    /// Fresh (uncached) input tokens billed at full input price.
    public let inputTokens: Int

    /// Output tokens billed at output price.
    public let outputTokens: Int

    /// Tokens billed at cache-creation price.
    public let cacheCreationInputTokens: Int

    /// Tokens billed at cache-read price (the cheap tier).
    public let cacheReadInputTokens: Int

    /// Total bytes consumed from any input source. Useful for "burn rate"
    /// projections regardless of which cache tier each token landed in.
    public var totalInputTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    /// Combined cost using the pricing table. Returns `nil` when the model id
    /// isn't in the table (UI shows "?" / cost = unknown).
    public var costUSD: Double? {
        Pricing.cost(
            modelID: model,
            inputTokens: inputTokens + cacheCreationInputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cacheReadInputTokens
        )
    }

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

/// Aggregated counts over a set of records — e.g. all events in the current
/// 5h session window.
public struct ClaudeUsageTotals: Equatable, Sendable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationInputTokens: Int = 0
    public var cacheReadInputTokens: Int = 0
    /// `nil` if any record had an unknown-model cost (we explicitly avoid
    /// inventing partial sums in that case so callers can show "?" honestly).
    public var costUSD: Double? = 0
    public var recordCount: Int = 0

    public var totalInputTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    public var isEmpty: Bool { recordCount == 0 }

    public init() {}

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        costUSD: Double? = nil,
        recordCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.costUSD = costUSD
        self.recordCount = recordCount
    }

    public mutating func add(_ record: ClaudeUsageRecord) {
        inputTokens += record.inputTokens
        outputTokens += record.outputTokens
        cacheCreationInputTokens += record.cacheCreationInputTokens
        cacheReadInputTokens += record.cacheReadInputTokens
        recordCount += 1
        switch (costUSD, record.costUSD) {
        case (.some(let lhs), .some(let rhs)):
            costUSD = lhs + rhs
        case (.none, _), (_, .none):
            // Once any record has unknown cost, the running sum is no longer
            // honest. Propagate nil rather than silently dropping that record.
            costUSD = nil
        }
    }

    public static func sum(_ records: [ClaudeUsageRecord]) -> ClaudeUsageTotals {
        var totals = ClaudeUsageTotals()
        for record in records {
            totals.add(record)
        }
        return totals
    }
}
