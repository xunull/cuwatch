import XCTest
@testable import CuwatchCore

final class MinimaxClientTests: XCTestCase {

    // MARK: - Endpoint helpers

    func testEndpointBaseURLs() {
        // Note the trailing `i` in `minimaxi` — official Minimax developer brand
        // (corrected 2026-06-21; old hosts minimax.io/minimax.cn were wrong).
        XCTAssertEqual(MinimaxEndpoint.global.baseURL.absoluteString, "https://api.minimaxi.com")
        XCTAssertEqual(MinimaxEndpoint.china.baseURL.absoluteString, "https://api.minimaxi.cn")
        XCTAssertEqual(MinimaxEndpoint.default, .global)
    }

    // MARK: - Successful responses
    //
    // Real API response shape verified 2026-06-21 via curl on the user's
    // production token. The response wraps per-model quota buckets inside
    // `model_remains[]` and reports remaining as an integer percent.

    /// Verbatim trimmed copy of the live response: two models (general at 97%,
    /// video at 100%). Dial should show 97% — the more constrained budget.
    private static let realLiveResponseBody = """
    {"model_remains":[
        {"start_time":1782007200000,"end_time":1782025200000,"remains_time":1104989,
         "current_interval_total_count":0,"current_interval_usage_count":0,
         "model_name":"general","current_weekly_total_count":0,
         "current_weekly_usage_count":0,"weekly_start_time":1781452800000,
         "weekly_end_time":1782057600000,"weekly_remains_time":33504989,
         "current_interval_status":1,"current_interval_remaining_percent":97,
         "current_weekly_status":3,"current_weekly_remaining_percent":100},
        {"start_time":1781971200000,"end_time":1782057600000,"remains_time":33504989,
         "current_interval_total_count":0,"current_interval_usage_count":0,
         "model_name":"video","current_weekly_total_count":0,
         "current_weekly_usage_count":0,"weekly_start_time":1781452800000,
         "weekly_end_time":1782057600000,"weekly_remains_time":33504989,
         "current_interval_status":3,"current_interval_remaining_percent":100,
         "current_weekly_status":3,"current_weekly_remaining_percent":100}],
     "base_resp":{"status_code":0,"status_msg":"success"}}
    """

    func testRealLiveResponseParsesIntoSnapshot() async throws {
        // Real response: general=97% remaining, video=100% remaining.
        // After flip to used semantics: general=3% used, video=0% used.
        // Most-used model wins → general at 3% used.
        let body = Self.realLiveResponseBody.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        let snapshot = try await client.fetchRemaining(token: "real_token")
        XCTAssertEqual(snapshot.service, .minimax)
        XCTAssertEqual(snapshot.window, .tokenBudget)
        XCTAssertEqual(snapshot.usedFraction, 0.03, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usageDisplay?.used, "3%")
        XCTAssertEqual(snapshot.usageDisplay?.total, "100%")
        XCTAssertEqual(snapshot.usageDisplay?.unit, "general")
        // end_time 1782025200000 ms → resetAt
        XCTAssertNotNil(snapshot.resetAt)
        XCTAssertEqual(snapshot.resetAt!.timeIntervalSince1970, 1_782_025_200, accuracy: 0.01)
    }

    func testEmptyModelRemainsArrayReturnsZeroUsedInsteadOfError() async throws {
        let body = """
        {"model_remains":[],"base_resp":{"status_code":0,"status_msg":"success"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        let snapshot = try await client.fetchRemaining(token: "t")
        XCTAssertEqual(snapshot.usedFraction, 0.0)
        XCTAssertNil(snapshot.usageDisplay)
    }

    func testHighestUsedPercentAcrossModelsWins() async throws {
        // Three models: remaining 45 / 12 / 99 → used 55 / 88 / 1.
        // Most-used = general at 88% used.
        let body = """
        {"model_remains":[
            {"model_name":"abab","start_time":0,"end_time":1000,
             "current_interval_remaining_percent":45,
             "current_weekly_remaining_percent":80},
            {"model_name":"general","start_time":0,"end_time":1000,
             "current_interval_remaining_percent":12,
             "current_weekly_remaining_percent":50},
            {"model_name":"video","start_time":0,"end_time":1000,
             "current_interval_remaining_percent":99,
             "current_weekly_remaining_percent":100}],
         "base_resp":{"status_code":0,"status_msg":"success"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        let snapshot = try await client.fetchRemaining(token: "t")
        XCTAssertEqual(snapshot.usedFraction, 0.88, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usageDisplay?.unit, "general")
    }

    func testHeaderFallbackUsedWhenBodyMalformed() async throws {
        // Header reports 30/100 remaining = 70% used after flip.
        let garbage = "<html>oops not json</html>".data(using: .utf8)!
        let headers: [AnyHashable: Any] = [
            "X-RateLimit-Remaining": "30",
            "X-RateLimit-Limit": "100",
        ]
        let session = StubSession(responses: [.success(200, garbage, headers)])
        let client = MinimaxClient(session: session)
        let snapshot = try await client.fetchRemaining(token: "t")
        XCTAssertEqual(snapshot.usedFraction, 0.7, accuracy: 0.0001)
        XCTAssertNil(snapshot.usageDisplay)
    }

    func testHeaderFallbackParsesResetSecondsDelta() async throws {
        let garbage = "garbage".data(using: .utf8)!
        let headers: [AnyHashable: Any] = [
            "X-RateLimit-Remaining": "30",
            "X-RateLimit-Limit": "100",
            "X-RateLimit-Reset": "60",
        ]
        let session = StubSession(responses: [.success(200, garbage, headers)])
        let client = MinimaxClient(session: session)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try await client.fetchRemaining(token: "t", now: now)
        XCTAssertNotNil(snapshot.resetAt)
        XCTAssertEqual(snapshot.resetAt!.timeIntervalSince(now), 60, accuracy: 0.01)
    }

    func testHeaderFallbackParsesResetAsAbsoluteEpoch() async throws {
        let garbage = "garbage".data(using: .utf8)!
        let absoluteEpoch: Double = 1_700_001_000
        let headers: [AnyHashable: Any] = [
            "X-RateLimit-Remaining": "30",
            "X-RateLimit-Limit": "100",
            "X-RateLimit-Reset": "\(Int(absoluteEpoch))",
        ]
        let session = StubSession(responses: [.success(200, garbage, headers)])
        let client = MinimaxClient(session: session)
        let snapshot = try await client.fetchRemaining(token: "t")
        XCTAssertEqual(snapshot.resetAt!.timeIntervalSince1970, absoluteEpoch, accuracy: 0.01)
    }

    // MARK: - Failure paths

    func testHTTP401MapsToAuthExpired() async {
        let session = StubSession(responses: [.success(401, Data(), [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "expired")
        ) { err in
            guard let m = err as? MinimaxError else { return XCTFail("wrong error type") }
            XCTAssertEqual(m, .authExpired)
            XCTAssertEqual(m.monitorFailureReason, .authExpired)
        }
    }

    func testHTTP429MapsToRateLimited() async {
        let session = StubSession(responses: [.success(429, Data(), [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .rateLimited)
            XCTAssertEqual((err as? MinimaxError)?.monitorFailureReason, .rateLimited)
        }
    }

    func testHTTP5xxMapsToServerError() async {
        let session = StubSession(responses: [.success(503, Data(), [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .serverError(503))
            XCTAssertEqual((err as? MinimaxError)?.monitorFailureReason, .networkError)
        }
    }

    func testTimeoutMapsToTimeoutFailureReason() async {
        let session = StubSession(responses: [.failure(URLError(.timedOut))])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            if case .urlError(let urlError) = (err as? MinimaxError) {
                XCTAssertEqual(urlError.code, .timedOut)
                XCTAssertEqual((err as? MinimaxError)?.monitorFailureReason, .timeout)
            } else {
                XCTFail("expected urlError(.timedOut)")
            }
        }
    }

    func testDNSFailureMapsToNetworkError() async {
        let session = StubSession(responses: [.failure(URLError(.cannotFindHost))])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual((err as? MinimaxError)?.monitorFailureReason, .networkError)
        }
    }

    // MARK: - base_resp envelope (HTTP 200 with business error)

    /// Verified 2026-06-21 via probe: api.minimaxi.com returns HTTP 200 with
    /// `{"base_resp":{"status_code":1004,"status_msg":"login fail..."}}` when
    /// the API key is missing/wrong. Without this check the client misclassifies
    /// auth failures as malformed JSON and the Minimax row gets stuck in
    /// `.parseError` backingOff state — exactly the "数据没显示" symptom.
    func testHTTP200WithStatusCode1004MapsToAuthExpired() async {
        let body = """
        {"base_resp":{"status_code":1004,"status_msg":"login fail"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "wrong")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .authExpired)
        }
    }

    func testHTTP200WithStatusCode1002MapsToRateLimited() async {
        let body = """
        {"base_resp":{"status_code":1002,"status_msg":"rate limit"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .rateLimited)
        }
    }

    func testHTTP200WithStatusCode1008MapsToQuotaExhausted() async {
        let body = """
        {"base_resp":{"status_code":1008,"status_msg":"insufficient balance"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .quotaExhausted)
        }
    }

    func testHTTP200WithUnknownNonZeroStatusCodeReturnsBaseRespError() async {
        let body = """
        {"base_resp":{"status_code":9999,"status_msg":"some new error"}}
        """.data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            XCTAssertEqual(err as? MinimaxError, .baseRespError(9999, "some new error"))
        }
    }

    func testMalformedJSONWithoutHeaderFallbackThrowsParseError() async {
        let body = "not json".data(using: .utf8)!
        let session = StubSession(responses: [.success(200, body, [:])])
        let client = MinimaxClient(session: session)
        await XCTAssertThrowsErrorAsync(
            try await client.fetchRemaining(token: "t")
        ) { err in
            if case .malformedJSON = (err as? MinimaxError) {
                // ok
            } else {
                XCTFail("expected malformedJSON, got \(err)")
            }
            if case .parseError = (err as? MinimaxError)?.monitorFailureReason {
                // ok
            } else {
                XCTFail("expected parseError reason")
            }
        }
    }

    // MARK: - Request shape

    func testRequestIncludesBearerHeader() async throws {
        let session = StubSession(responses: [.success(200, """
        {"model_remains":[{"model_name":"general","start_time":0,"end_time":1000,"current_interval_remaining_percent":50,"current_weekly_remaining_percent":50}],"base_resp":{"status_code":0,"status_msg":"success"}}
        """.data(using: .utf8)!, [:])])
        let client = MinimaxClient(session: session)
        _ = try await client.fetchRemaining(token: "mxp_my_token")
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer mxp_my_token")
        XCTAssertEqual(session.lastRequest?.url?.absoluteString,
                       "https://api.minimaxi.com/v1/token_plan/remains")
        XCTAssertEqual(session.lastRequest?.httpMethod, "GET")
    }

    func testEndpointSwitchChangesURL() async throws {
        let session = StubSession(responses: [.success(200, """
        {"model_remains":[{"model_name":"general","start_time":0,"end_time":1000,"current_interval_remaining_percent":50,"current_weekly_remaining_percent":50}],"base_resp":{"status_code":0,"status_msg":"success"}}
        """.data(using: .utf8)!, [:])])
        let client = MinimaxClient(endpoint: .china, session: session)
        _ = try await client.fetchRemaining(token: "t")
        XCTAssertEqual(session.lastRequest?.url?.absoluteString,
                       "https://api.minimaxi.cn/v1/token_plan/remains")
    }
}

// MARK: - URLSessionProtocol stub

private final class StubSession: URLSessionProtocol, @unchecked Sendable {

    enum Response {
        case success(Int, Data, [AnyHashable: Any])
        case failure(URLError)
    }

    private var responses: [Response]
    private(set) var lastRequest: URLRequest?

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        guard !responses.isEmpty else {
            throw URLError(.cancelled)
        }
        let next = responses.removeFirst()
        switch next {
        case .failure(let urlError):
            throw urlError
        case .success(let code, let body, let headers):
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers.reduce(into: [String: String]()) { acc, kv in
                    if let key = kv.key as? String { acc[key] = "\(kv.value)" }
                }
            )!
            return (body, resp)
        }
    }
}

// MARK: - Async XCTest helper

/// Tiny adapter that lets us use `XCTAssertThrowsError`-style checks inside async tests.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw, got success. \(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
