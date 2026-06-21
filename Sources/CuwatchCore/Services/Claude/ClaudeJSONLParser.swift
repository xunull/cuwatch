import Foundation

/// Parses a single Claude Code JSONL file into `ClaudeUsageRecord`s.
///
/// Schema reference (from observed `~/.claude/projects/<p>/<session>.jsonl`):
/// ```
/// {"type":"user","timestamp":"2026-06-13T10:00:00Z","message":{...}}
/// {"type":"assistant","timestamp":"2026-06-13T10:00:05Z",
///  "message":{
///    "model":"claude-opus-4-7",
///    "usage":{
///      "input_tokens":100,
///      "output_tokens":50,
///      "cache_creation_input_tokens":0,
///      "cache_read_input_tokens":2000
///    }
///  }
/// }
/// ```
///
/// Only `type == "assistant"` events with a populated `usage` block become
/// records. Everything else is skipped. Corrupt lines (non-JSON, truncated,
/// missing fields) are skipped and counted; the parser never throws on a bad
/// line, so a half-written tail never crashes a poll.
public struct ClaudeJSONLParser {

    public struct ParseResult: Equatable, Sendable {
        public let records: [ClaudeUsageRecord]
        public let totalLines: Int
        /// Lines that didn't decode as JSON or were missing required fields.
        public let malformedLines: Int

        public var malformedFraction: Double {
            guard totalLines > 0 else { return 0 }
            return Double(malformedLines) / Double(totalLines)
        }
    }

    public init() {}

    /// Parse a single JSONL file's contents.
    /// - Parameter data: raw bytes of the JSONL file (UTF-8 expected).
    /// - Returns: a `ParseResult` containing decoded records and skip counts.
    public func parse(data: Data) -> ParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return ParseResult(records: [], totalLines: 0, malformedLines: 0)
        }
        return parse(text: text)
    }

    public func parse(text: String) -> ParseResult {
        var records: [ClaudeUsageRecord] = []
        var totalLines = 0
        var malformed = 0

        let decoder = makeDecoder()

        text.enumerateLines { line, _ in
            // Skip empty lines silently — they aren't malformed, just whitespace.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            totalLines += 1
            guard let lineData = trimmed.data(using: .utf8) else {
                malformed += 1
                return
            }
            do {
                let event = try decoder.decode(EventLine.self, from: lineData)
                guard event.type == "assistant" else {
                    // Not a record-bearing event. Not malformed, just irrelevant.
                    totalLines -= 1
                    return
                }
                guard let message = event.message, let usage = message.usage else {
                    // Assistant event with no usage info — skip but count as malformed
                    // (it's an anomaly worth surfacing in diagnostics).
                    malformed += 1
                    return
                }
                guard let timestamp = parseTimestamp(event.timestamp) else {
                    malformed += 1
                    return
                }
                let modelID = message.model ?? "unknown_model"
                records.append(ClaudeUsageRecord(
                    timestamp: timestamp,
                    model: modelID,
                    inputTokens: usage.inputTokens ?? 0,
                    outputTokens: usage.outputTokens ?? 0,
                    cacheCreationInputTokens: usage.cacheCreationInputTokens ?? 0,
                    cacheReadInputTokens: usage.cacheReadInputTokens ?? 0
                ))
            } catch {
                malformed += 1
            }
        }

        return ParseResult(
            records: records,
            totalLines: totalLines,
            malformedLines: malformed
        )
    }

    // MARK: - Wire schema

    private struct EventLine: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    // MARK: - Helpers

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        // We parse timestamps manually because the format varies (with / without
        // fractional seconds) and JSONDecoder's iso8601 strategy is strict.
        return d
    }

    /// Parse the various ISO-8601 timestamp shapes Claude Code emits:
    ///   "2026-06-13T10:00:00Z"
    ///   "2026-06-13T10:00:00.123Z"
    ///   "2026-06-13T10:00:00+00:00"
    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = Self.fractionalFormatter.date(from: raw) { return date }
        if let date = Self.plainFormatter.date(from: raw) { return date }
        // Last-resort: try ISO8601DateFormatter with all bells.
        return Self.fallbackFormatter.date(from: raw)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
            .withTimeZone,
            .withColonSeparatorInTimeZone,
        ]
        return f
    }()
}
