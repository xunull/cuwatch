import Foundation

/// Reads Minimax Token Plan remaining quota over HTTPS.
///
/// Calls `GET <endpoint>/v1/token_plan/remains` with a `Bearer <token>` header
/// and parses the JSON response. The exact response schema is provider-defined
/// and may shift; we decode tolerantly and surface the documented "remaining
/// percentage" + "total / remaining tokens" pair into a `UsageSnapshot`.
///
/// Failure modes (each maps onto a `MonitorFailureReason` for the caller):
/// - HTTP 401/403 → token invalid → `.authExpired`
/// - HTTP 429    → rate limited  → `.rateLimited`
/// - HTTP 5xx    → server error  → `.networkError` (retry with backoff)
/// - URLError    → network error → `.networkError` / `.timeout`
/// - JSON malformed → `.parseError`
public final class MinimaxClient {

    public var endpoint: MinimaxEndpoint
    public let session: URLSessionProtocol
    public let timeout: TimeInterval

    public init(
        endpoint: MinimaxEndpoint = .default,
        session: URLSessionProtocol = URLSession.shared,
        timeout: TimeInterval = 15
    ) {
        self.endpoint = endpoint
        self.session = session
        self.timeout = timeout
    }

    // MARK: - Public API

    public func fetchRemaining(token: String, now: Date = Date()) async throws -> UsageSnapshot {
        let url = endpoint.baseURL.appendingPathComponent("v1/token_plan/remains")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("cuwatch/0.0.1", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw MinimaxError.urlError(error)
        } catch {
            throw MinimaxError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MinimaxError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return try parseSuccessfulResponse(data: data, headers: http.allHeaderFields, now: now)
        case 401, 403:
            throw MinimaxError.authExpired
        case 429:
            throw MinimaxError.rateLimited
        case 500..<600:
            throw MinimaxError.serverError(http.statusCode)
        default:
            throw MinimaxError.unexpectedStatus(http.statusCode)
        }
    }

    // MARK: - Response parsing

    func parseSuccessfulResponse(
        data: Data,
        headers: [AnyHashable: Any],
        now: Date
    ) throws -> UsageSnapshot {
        // Minimax wraps EVERY response in `base_resp: { status_code, status_msg }`
        // and returns HTTP 200 even on auth / rate-limit / business errors.
        // Check the inner status BEFORE trying to decode the data payload.
        if let baseResp = try? JSONDecoder().decode(BaseRespEnvelope.self, from: data),
           baseResp.base_resp.status_code != 0 {
            throw mapBaseRespCodeToError(baseResp.base_resp)
        }

        // Try the documented JSON shape first.
        let decoder = JSONDecoder()
        let payload: RemainsResponse
        do {
            payload = try decoder.decode(RemainsResponse.self, from: data)
        } catch {
            // Fall back to X-RateLimit-* headers, if the body shape isn't known.
            // Header fraction reported as `remaining/total`; we flip to used
            // before publishing so it matches the rest of the codebase.
            if let remainingFraction = fractionFromRateLimitHeaders(headers) {
                return UsageSnapshot(
                    service: .minimax,
                    readAt: now,
                    window: .tokenBudget,
                    usedFraction: max(0, min(1.0, 1.0 - remainingFraction)),
                    resetAt: resetAtFromHeaders(headers, now: now),
                    usageDisplay: nil
                )
            }
            throw MinimaxError.malformedJSON(error.localizedDescription)
        }

        // Pick the **most-used** model across all entries — matches the
        // dial's intent of "warn when ANY metered budget is running low" and
        // mirrors how the user thinks ("can I still use Minimax right now").
        // If the array is empty (server quirk), fall back to 0% used with no
        // display so the row at least doesn't show parse error.
        guard let headlineModel = payload.mostUsedModel() else {
            return UsageSnapshot(
                service: .minimax,
                readAt: now,
                window: .tokenBudget,
                usedFraction: 0.0,
                resetAt: nil,
                usageDisplay: nil
            )
        }
        let usedPercent = 100 - headlineModel.current_interval_remaining_percent
        let fraction = max(0, min(1.0, Double(usedPercent) / 100.0))
        let display = UsageDisplay(
            used: "\(usedPercent)%",
            total: "100%",
            unit: headlineModel.model_name
        )
        // Minimax timestamps are ms-since-epoch. end_time is when the current
        // interval resets.
        let resetAt = Date(timeIntervalSince1970: Double(headlineModel.end_time) / 1000.0)

        return UsageSnapshot(
            service: .minimax,
            readAt: now,
            window: .tokenBudget,
            usedFraction: fraction,
            resetAt: resetAt,
            usageDisplay: display
        )
    }

    /// Fallback: derive remaining fraction from `X-RateLimit-Remaining` /
    /// `X-RateLimit-Limit`.
    private func fractionFromRateLimitHeaders(_ headers: [AnyHashable: Any]) -> Double? {
        guard let remaining = doubleHeader(headers, name: "X-RateLimit-Remaining"),
              let total = doubleHeader(headers, name: "X-RateLimit-Limit"),
              total > 0 else {
            return nil
        }
        return max(0, min(1, remaining / total))
    }

    private func resetAtFromHeaders(_ headers: [AnyHashable: Any], now: Date) -> Date? {
        guard let reset = doubleHeader(headers, name: "X-RateLimit-Reset") else { return nil }
        // Could be a delta-seconds value (`30`) or an absolute UTC epoch (`1718239300`).
        // Heuristic: anything > 10^9 is treated as absolute.
        return reset > 1_000_000_000
            ? Date(timeIntervalSince1970: reset)
            : now.addingTimeInterval(reset)
    }

    private func doubleHeader(_ headers: [AnyHashable: Any], name: String) -> Double? {
        for (k, v) in headers {
            guard let key = k as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            if let n = v as? Double { return n }
            if let s = v as? String, let n = Double(s) { return n }
            if let n = v as? Int { return Double(n) }
            if let n = v as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000
            return String(format: "%.1fM", m)
        }
        if count >= 1_000 {
            let k = Double(count) / 1_000
            return String(format: "%.0fk", k)
        }
        return "\(count)"
    }

    /// Minimax error code → MinimaxError mapping. Codes verified 2026-06-21
    /// against api.minimaxi.com probe responses.
    /// Reference: https://platform.minimaxi.com/docs/guides/errors
    private func mapBaseRespCodeToError(_ resp: BaseResp) -> MinimaxError {
        switch resp.status_code {
        case 1000, 1001:                  return .serverError(resp.status_code)
        case 1002, 1039:                  return .rateLimited
        case 1004, 1010, 1015, 1042:      return .authExpired
        case 1008:                        return .quotaExhausted
        case 2013, 2049:                  return .authExpired
        default:                          return .baseRespError(resp.status_code, resp.status_msg)
        }
    }

    // MARK: - Wire schema

    /// Outer envelope that EVERY Minimax response (including this one) ships
    /// with. `status_code == 0` means business-level success; any non-zero
    /// code is an error even when the HTTP status is 200.
    struct BaseRespEnvelope: Decodable {
        let base_resp: BaseResp
    }
    struct BaseResp: Decodable, Equatable {
        let status_code: Int
        let status_msg: String
    }


    /// Decode of the real `/v1/token_plan/remains` response, verified 2026-06-21
    /// with a live API key. Top-level `model_remains[]` carries one entry per
    /// model (e.g. "general", "video"); each entry has its own interval +
    /// weekly windows. The headline number for the dial is
    /// `current_interval_remaining_percent` (0-100 integer). `end_time` is the
    /// **ms** epoch when the interval resets.
    struct RemainsResponse: Decodable {
        let model_remains: [ModelRemain]
        let base_resp: BaseResp

        /// Pick the model with the **highest** used % (= lowest interval
        /// remaining %) so the dial reflects "the most constrained budget
        /// right now". Stable tiebreak by `model_name` for deterministic display.
        func mostUsedModel() -> ModelRemain? {
            model_remains.min { lhs, rhs in
                if lhs.current_interval_remaining_percent != rhs.current_interval_remaining_percent {
                    return lhs.current_interval_remaining_percent < rhs.current_interval_remaining_percent
                }
                return lhs.model_name < rhs.model_name
            }
        }
    }

    struct ModelRemain: Decodable, Equatable {
        let model_name: String
        let start_time: Int64
        let end_time: Int64
        let current_interval_remaining_percent: Int
        let current_weekly_remaining_percent: Int
        let current_interval_total_count: Int?
        let current_interval_usage_count: Int?
    }
}

// MARK: - Errors

public enum MinimaxError: Error, Equatable, Sendable {
    case authExpired
    case rateLimited
    case quotaExhausted
    case serverError(Int)
    case unexpectedStatus(Int)
    case invalidResponse
    case urlError(URLError)
    case transport(String)
    case malformedJSON(String)
    /// HTTP 200 + `base_resp.status_code != 0` not covered by the explicit cases.
    case baseRespError(Int, String)
}

extension MinimaxError {
    /// Map an `Error` thrown by `fetchRemaining` onto the monitor failure reason.
    public var monitorFailureReason: MonitorFailureReason {
        switch self {
        case .authExpired: return .authExpired
        case .rateLimited: return .rateLimited
        case .quotaExhausted: return .rateLimited
        case .serverError: return .networkError
        case .unexpectedStatus: return .networkError
        case .invalidResponse: return .parseError(message: "invalid HTTP response")
        case .urlError(let e):
            if e.code == .timedOut { return .timeout }
            return .networkError
        case .transport: return .networkError
        case .malformedJSON(let msg): return .parseError(message: msg)
        case .baseRespError(let code, let msg):
            return .parseError(message: "minimax error \(code): \(msg)")
        }
    }
}

// MARK: - URLSession abstraction

/// Indirection over `URLSession.data(for:)` so tests can inject canned responses
/// without spinning up an HTTP server. Production binds to `URLSession.shared`.
public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
