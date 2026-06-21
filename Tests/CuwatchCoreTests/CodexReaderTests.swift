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

    func testAuthenticatedWithRecentSessionFileExtractsStart() throws {
        try writeAuthJSON()
        // Add a session file inside sessions/ with mtime 30 min ago.
        let sessionsDir = tempHome.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionFile = sessionsDir.appendingPathComponent("session-current.json")
        try Data("{}".utf8).write(to: sessionFile)
        let recentMtime = Date().addingTimeInterval(-30 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: recentMtime], ofItemAtPath: sessionFile.path
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read(now: Date())
        if case .authenticated(let start) = result.probe {
            XCTAssertNotNil(start)
        } else {
            XCTFail("expected authenticated probe, got \(result.probe)")
        }
        // Snapshot with time-used fraction near 10% (30 min into a 5h window).
        XCTAssertNotNil(result.snapshot)
        XCTAssertEqual(result.snapshot?.usedFraction ?? 0, (30 * 60.0) / (5 * 3600), accuracy: 0.05)
        XCTAssertEqual(result.snapshot?.service, .codex)
        XCTAssertEqual(result.snapshot?.window, .sessionWindow5h)
    }

    func testAuthenticatedButSessionFileTooOldReturnsNilSnapshot() throws {
        try writeAuthJSON()
        let sessionsDir = tempHome.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let sessionFile = sessionsDir.appendingPathComponent("session-stale.json")
        try Data("{}".utf8).write(to: sessionFile)
        // 8h ago — beyond the 5h session window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 3600)],
            ofItemAtPath: sessionFile.path
        )

        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read()
        if case .authenticated(let start) = result.probe {
            // No recent session within 5h.
            XCTAssertNil(start)
        } else {
            XCTFail("expected authenticated probe")
        }
        XCTAssertNil(result.snapshot)
    }

    func testAuthenticatedWithNoSessionFilesReturnsNilSnapshot() throws {
        try writeAuthJSON()
        // No session files at all.
        let reader = CodexReader(homeDirectory: tempHome)
        let result = reader.read()
        XCTAssertEqual(result.probe, .authenticated(sessionStart: nil))
        XCTAssertNil(result.snapshot)
    }
}
