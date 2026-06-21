import XCTest
@testable import CuwatchCore

final class CodexReaderTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-codex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        tempHome = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCodexDir() throws {
        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
    }

    private func writeAuthJSON(_ contents: String = "{}") throws {
        try makeCodexDir()
        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        try contents.data(using: .utf8)!.write(to: codexDir.appendingPathComponent("auth.json"))
    }

    // MARK: - binary-not-installed
    //
    // Regression for 2026-06-21 fix: the probe used to walk `$PATH` for the
    // `codex` binary, which always failed for macOS GUI apps (their inherited
    // PATH is the system default `/usr/bin:/bin:/usr/sbin:/sbin`, NOT the
    // user's shell PATH). The fix swaps the signal to "does `~/.codex/` exist".

    func testNoCodexDirectoryReturnsNotInstalled() {
        // Fresh tempHome has no `.codex/` subdirectory.
        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read()
        XCTAssertEqual(result.probe, .binaryNotInstalled)
        XCTAssertNil(result.snapshot)
    }

    func testCodexDotfileAsRegularFileStillCountsAsNotInstalled() throws {
        // Edge case: someone has a *file* named `.codex` (not a directory).
        let stray = tempHome.appendingPathComponent(".codex")
        try Data("not a directory".utf8).write(to: stray)
        let reader = CodexReader(homeDirectory: tempHome)
        XCTAssertEqual(reader.read().probe, .binaryNotInstalled)
    }

    // MARK: - not-authenticated

    func testCodexDirectoryButNoAuthFile() throws {
        try makeCodexDir()
        // No `~/.codex/auth.json` written.
        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read()
        XCTAssertEqual(result.probe, .notAuthenticated)
        XCTAssertNil(result.snapshot)
    }

    func testCodexDirectoryButAuthFileEmpty() throws {
        try makeCodexDir()
        let codexDir = tempHome.appendingPathComponent(".codex", isDirectory: true)
        // Empty auth.json — treat as not authenticated.
        try Data().write(to: codexDir.appendingPathComponent("auth.json"))

        let reader = CodexReader(homeDirectory: tempHome)
        XCTAssertEqual(reader.read().probe, .notAuthenticated)
    }

    // MARK: - authenticated

    /// Helper: write a `rollout-*.jsonl` at the real codex layout
    /// `~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl`.
    /// The session-start timestamp is encoded INTO the filename — that's
    /// what the reader now parses (not file mtime).
    @discardableResult
    private func writeRolloutFile(sessionStart: Date,
                                  uuidSuffix: String = "019e8cbf-7fcd-74e0-ab17-73b8b34c1128") throws -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let comp = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: sessionStart
        )
        let y = String(format: "%04d", comp.year!)
        let m = String(format: "%02d", comp.month!)
        let d = String(format: "%02d", comp.day!)
        let h = String(format: "%02d", comp.hour!)
        let mi = String(format: "%02d", comp.minute!)
        let s = String(format: "%02d", comp.second!)
        let dayDir = tempHome
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent(d, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let name = "rollout-\(y)-\(m)-\(d)T\(h)-\(mi)-\(s)-\(uuidSuffix).jsonl"
        let file = dayDir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        return file
    }

    func testAuthenticatedWithRecentRolloutFileExtractsStartFromFilename() throws {
        try writeAuthJSON()
        let now = Date()
        // Session started 30 min ago — encoded in the filename, NOT mtime.
        let sessionStart = now.addingTimeInterval(-30 * 60)
        _ = try writeRolloutFile(sessionStart: sessionStart)

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        if case .authenticated(let start) = result.probe {
            XCTAssertNotNil(start)
            // Filename-encoded resolution is second-precision, so allow
            // up to 1s of clock skew.
            XCTAssertEqual(start!.timeIntervalSince(sessionStart), 0, accuracy: 1.0)
        } else {
            XCTFail("expected authenticated probe, got \(result.probe)")
        }
        // Time-used fraction near 10% (30 min into a 5h window).
        XCTAssertNotNil(result.snapshot)
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, (30 * 60.0) / (5 * 3600), accuracy: 0.05)
        XCTAssertEqual(result.snapshot?.service, .codex)
        XCTAssertEqual(result.snapshot?.window, .sessionWindow5h)
    }

    /// Regression for 2026-06-21: codex CLI does background bookkeeping that
    /// touches old rollout files. An mtime-based reader misreads those as
    /// active sessions. With filename-parsing the false positive vanishes.
    func testOldFilenameIgnoredEvenIfMtimeWasJustTouched() throws {
        try writeAuthJSON()
        let now = Date()
        let trulyOld = now.addingTimeInterval(-72 * 3600) // 3 days ago
        let file = try writeRolloutFile(sessionStart: trulyOld)
        // Simulate codex's background touch: bump mtime to "right now".
        try FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: file.path
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        if case .authenticated(let start) = result.probe {
            XCTAssertNil(start, "filename-encoded start was 3 days ago — must not surface as active")
        } else {
            XCTFail("expected authenticated probe, got \(result.probe)")
        }
        XCTAssertNil(result.snapshot)
    }

    func testAuthenticatedButSessionFileTooOldReturnsNilSnapshot() throws {
        try writeAuthJSON()
        let now = Date()
        // 8h ago — beyond the 5h session window.
        _ = try writeRolloutFile(sessionStart: now.addingTimeInterval(-8 * 3600))

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        if case .authenticated(let start) = result.probe {
            XCTAssertNil(start)
        } else {
            XCTFail("expected authenticated probe")
        }
        XCTAssertNil(result.snapshot)
    }

    func testAuthenticatedWithNoSessionFilesReturnsNilSnapshot() throws {
        try writeAuthJSON()
        // No rollout files at all.
        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read()
        XCTAssertEqual(result.probe, .authenticated(sessionStart: nil))
        XCTAssertNil(result.snapshot)
    }

    /// Codex used to maintain flat session JSONs (per the original spike
    /// assumption). The new layout is 3 levels deep — make sure we recurse
    /// rather than assume top-level files.
    func testRecursivelyDescendsIntoYYYYMMDDDirectories() throws {
        try writeAuthJSON()
        let now = Date()
        let sessionStart = now.addingTimeInterval(-45 * 60) // 45 min ago
        _ = try writeRolloutFile(sessionStart: sessionStart)

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        if case .authenticated(let start) = result.probe {
            XCTAssertNotNil(start, "should find rollout file 3 levels deep in sessions/YYYY/MM/DD/")
        } else {
            XCTFail("expected authenticated probe")
        }
        XCTAssertNotNil(result.snapshot)
    }

    /// When multiple recent rollouts coexist, the EARLIEST (=
    /// most-pessimistic session-start estimate) wins. Same semantic as the
    /// Claude reader: anchors used% to the oldest in-window event.
    func testMultipleRecentRolloutsPickEarliestStart() throws {
        try writeAuthJSON()
        let now = Date()
        let early = now.addingTimeInterval(-2 * 3600) // 2h ago
        let late = now.addingTimeInterval(-30 * 60)  // 30 min ago
        _ = try writeRolloutFile(sessionStart: late, uuidSuffix: "aaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        _ = try writeRolloutFile(sessionStart: early, uuidSuffix: "1111-2222-3333-4444-555555555555")

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        if case .authenticated(let start) = result.probe {
            XCTAssertEqual(start!.timeIntervalSince(early), 0, accuracy: 1.0)
        } else {
            XCTFail("expected authenticated probe")
        }
    }

    // MARK: - Filename parser (covers edge cases via the static helper)

    func testSessionStartFromFilenameAcceptsRealCodexLayout() {
        let start = CodexReader.sessionStartFromFilename(
            "rollout-2026-06-21T17-30-12-019e8cbf-7fcd-74e0-ab17-73b8b34c1128.jsonl"
        )
        XCTAssertNotNil(start)
        let comp = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: start!
        )
        XCTAssertEqual(comp.year, 2026)
        XCTAssertEqual(comp.month, 6)
        XCTAssertEqual(comp.day, 21)
        XCTAssertEqual(comp.hour, 17)
        XCTAssertEqual(comp.minute, 30)
        XCTAssertEqual(comp.second, 12)
    }

    func testSessionStartFromFilenameRejectsNonRollout() {
        XCTAssertNil(CodexReader.sessionStartFromFilename("session-2026-06-21T17-30-12.jsonl"))
        XCTAssertNil(CodexReader.sessionStartFromFilename("rollout-2026-06-21T17-30-12.json"))
        XCTAssertNil(CodexReader.sessionStartFromFilename("rollout-not-a-date-string.jsonl"))
        XCTAssertNil(CodexReader.sessionStartFromFilename("rollout-2026-06-21.jsonl"))
    }

    // MARK: - Real rate_limits parsing (2026-06-21)

    /// Helper: writes a synthetic rollout file containing `n` events, with
    /// the LAST event carrying a `payload.rate_limits` block built from the
    /// supplied parameters. Mirrors the real codex CLI's per-line JSON format.
    @discardableResult
    private func writeRolloutWithRateLimits(sessionStart: Date,
                                            primaryPct: Double,
                                            primaryWindowMinutes: Int = 300,
                                            primaryResetsAt: Date,
                                            secondaryPct: Double = 47.0,
                                            secondaryResetsAt: Date? = nil,
                                            planType: String = "plus",
                                            uuidSuffix: String = "019e8cbf-7fcd-74e0-ab17-73b8b34c1128",
                                            additionalRateLimitsLines: [(primaryPct: Double, resetsAt: Date)] = []) throws -> URL {
        let file = try writeRolloutFile(sessionStart: sessionStart, uuidSuffix: uuidSuffix)
        // Build the events sequence: a pre-rate event, then any extras, then
        // the FINAL event with the headline rate_limits we want detected.
        var lines: [String] = [
            #"{"type":"chat","payload":{"foo":"bar"}}"#
        ]
        for extra in additionalRateLimitsLines {
            let extraJSON = """
            {"type":"chat","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(extra.primaryPct),"window_minutes":300,"resets_at":\(Int(extra.resetsAt.timeIntervalSince1970))},"secondary":{"used_percent":\(secondaryPct),"window_minutes":10080,"resets_at":\(Int((secondaryResetsAt ?? extra.resetsAt).timeIntervalSince1970))},"plan_type":"\(planType)"}}}
            """
            lines.append(extraJSON)
        }
        let finalLine = """
        {"type":"chat","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primaryPct),"window_minutes":\(primaryWindowMinutes),"resets_at":\(Int(primaryResetsAt.timeIntervalSince1970))},"secondary":{"used_percent":\(secondaryPct),"window_minutes":10080,"resets_at":\(Int((secondaryResetsAt ?? primaryResetsAt).timeIntervalSince1970))},"plan_type":"\(planType)"}}}
        """
        lines.append(finalLine)
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file)
        return file
    }

    /// Regression for the "you read files but didn't see real usage" gap.
    /// Codex actually persists `payload.rate_limits.primary.used_percent`
    /// to each rollout event — same number the Codex desktop app shows.
    /// The reader must surface THIS, not the time-based proxy.
    func testReadsRealRateLimitsFromRolloutInsteadOfTimeProxy() throws {
        try writeAuthJSON()
        let now = Date()
        let sessionStart = now.addingTimeInterval(-90 * 60) // 90 min ago
        let resetsAt = now.addingTimeInterval(3 * 3600)
        _ = try writeRolloutWithRateLimits(
            sessionStart: sessionStart,
            primaryPct: 30.0,
            primaryResetsAt: resetsAt,
            secondaryPct: 47.0,
            planType: "plus"
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        XCTAssertNotNil(result.snapshot)
        // 30% used, NOT 30% via time (90min / 5h = 30% — coincidence here,
        // so check via the display strings + resetAt to disambiguate).
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, 0.30, accuracy: 0.001)
        XCTAssertEqual(result.snapshot?.usageDisplay?.used, "30%")
        XCTAssertEqual(result.snapshot?.usageDisplay?.unit, "plus")
        // resetAt comes from the rate_limits payload, NOT from sessionStart+5h.
        XCTAssertEqual(result.snapshot?.resetAt?.timeIntervalSince1970 ?? 0,
                       resetsAt.timeIntervalSince1970, accuracy: 1.0)
    }

    /// Multiple rate_limits events in the same file — the LAST one wins.
    func testRateLimitsLastSeenWins() throws {
        try writeAuthJSON()
        let now = Date()
        let sessionStart = now.addingTimeInterval(-60 * 60)
        let earlyResetsAt = now.addingTimeInterval(2 * 3600)
        let finalResetsAt = now.addingTimeInterval(4 * 3600)
        _ = try writeRolloutWithRateLimits(
            sessionStart: sessionStart,
            primaryPct: 87.0,                                  // headline (last)
            primaryResetsAt: finalResetsAt,
            additionalRateLimitsLines: [
                (primaryPct: 12.0, resetsAt: earlyResetsAt),   // earlier event
                (primaryPct: 50.0, resetsAt: earlyResetsAt),   // earlier event
            ]
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, 0.87, accuracy: 0.001)
        XCTAssertEqual(result.snapshot?.usageDisplay?.used, "87%")
    }

    /// Two rollout files with different start times — reader prefers the
    /// MOST-RECENT file's rate_limits (server state evolves over time, so
    /// the freshest write wins).
    func testReadsRateLimitsFromMostRecentFileNotOldest() throws {
        try writeAuthJSON()
        let now = Date()
        let oldStart = now.addingTimeInterval(-4 * 3600)
        let newStart = now.addingTimeInterval(-30 * 60)
        _ = try writeRolloutWithRateLimits(
            sessionStart: oldStart,
            primaryPct: 10.0,                                  // stale
            primaryResetsAt: now.addingTimeInterval(1 * 3600),
            uuidSuffix: "0000-aaaa-bbbb-cccc-dddddddddddd"
        )
        _ = try writeRolloutWithRateLimits(
            sessionStart: newStart,
            primaryPct: 65.0,                                  // fresh
            primaryResetsAt: now.addingTimeInterval(4 * 3600),
            uuidSuffix: "1111-eeee-ffff-aaaa-222222222222"
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, 0.65, accuracy: 0.001)
    }

    /// Plan-type is preserved as the display `unit` — so the popover row
    /// can show "30% • plus" (or pro, free, etc.) without extra plumbing.
    func testPlanTypeIsPreservedInDisplayUnit() throws {
        try writeAuthJSON()
        let now = Date()
        _ = try writeRolloutWithRateLimits(
            sessionStart: now.addingTimeInterval(-1 * 3600),
            primaryPct: 18.0,
            primaryResetsAt: now.addingTimeInterval(3 * 3600),
            planType: "pro"
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        XCTAssertEqual(result.snapshot?.usageDisplay?.unit, "pro")
    }

    /// If no rate_limits ever surfaces in the rollout (e.g. malformed file,
    /// pre-server-response state), fall back to the time-based proxy.
    /// This keeps the row alive instead of going idle for users mid-write.
    func testFallsBackToTimeProxyWhenRateLimitsAbsent() throws {
        try writeAuthJSON()
        let now = Date()
        // A file with NO rate_limits events.
        let sessionStart = now.addingTimeInterval(-90 * 60)
        let url = try writeRolloutFile(sessionStart: sessionStart)
        try #"{"type":"chat","payload":{"foo":"no_rate_limits_here"}}"#
            .data(using: .utf8)!.write(to: url)

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: now)
        XCTAssertNotNil(result.snapshot, "expected time-based proxy fallback")
        // 90 min / 5h = 30% — same number as the previous "real" test by
        // coincidence; here it comes from the proxy. Verify the proxy
        // signature: display is nil (proxy never sets it).
        XCTAssertNil(result.snapshot?.usageDisplay,
                     "proxy fallback should not synthesize a usageDisplay")
    }

    func testCodexRateLimitsParserAcceptsRealisticPayload() {
        let dict: [String: Any] = [
            "limit_id": "codex",
            "limit_name": NSNull(),
            "primary": [
                "used_percent": 30.0,
                "window_minutes": 300,
                "resets_at": 1782047345
            ],
            "secondary": [
                "used_percent": 47.0,
                "window_minutes": 10080,
                "resets_at": 1782377242
            ],
            "credits": NSNull(),
            "individual_limit": NSNull(),
            "plan_type": "plus",
            "rate_limit_reached_type": NSNull()
        ]
        let parsed = CodexRateLimits.from(dict)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.primaryUsedPercent, 30.0)
        XCTAssertEqual(parsed?.primaryWindowMinutes, 300)
        XCTAssertEqual(parsed?.primaryResetsAt.timeIntervalSince1970, 1782047345)
        XCTAssertEqual(parsed?.secondaryUsedPercent, 47.0)
        XCTAssertEqual(parsed?.secondaryWindowMinutes, 10080)
        XCTAssertEqual(parsed?.planType, "plus")
    }

    func testCodexRateLimitsParserRejectsMissingPrimary() {
        let dict: [String: Any] = ["limit_id": "codex"]
        XCTAssertNil(CodexRateLimits.from(dict))
    }
}
