import XCTest
@testable import CuwatchCore

final class HistoryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        let file = try store.load()
        XCTAssertEqual(file.version, 1)
        XCTAssertTrue(file.events.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        let events = [
            HistoryStore.Event(
                ts: Date(timeIntervalSince1970: 1_700_000_000),
                service: .claude,
                tokensIn: 12_000,
                tokensOut: 3_500,
                costUSD: 0.42,
                modelID: "claude-opus-4-7"
            ),
            HistoryStore.Event(
                ts: Date(timeIntervalSince1970: 1_700_000_300),
                service: .minimax,
                tokensIn: 4_000,
                tokensOut: 1_200,
                costUSD: 0.05,
                modelID: "minimax-m2-5"
            ),
        ]
        try store.save(HistoryStore.File(events: events))

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.version, 1)
        XCTAssertEqual(reloaded.events.count, 2)
        XCTAssertEqual(reloaded.events[0].service, .claude)
        XCTAssertEqual(reloaded.events[0].costUSD, 0.42)
        XCTAssertEqual(reloaded.events[1].service, .minimax)
    }

    func testCleanupOrphansDeletesOldTmpFiles() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        // Create three orphan .tmp files: two old, one fresh.
        let oldTmp1 = tempDir.appendingPathComponent("history.json.tmp")
        let oldTmp2 = tempDir.appendingPathComponent("foo.tmp")
        let freshTmp = tempDir.appendingPathComponent("bar.tmp")
        try Data().write(to: oldTmp1)
        try Data().write(to: oldTmp2)
        try Data().write(to: freshTmp)

        // Manually backdate the two we want considered orphans.
        let oldDate = Date().addingTimeInterval(-30 * 60) // 30 minutes ago
        let freshDate = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: oldTmp1.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: oldTmp2.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: freshDate], ofItemAtPath: freshTmp.path
        )

        // Cleanup with default maxAge (5 min) — should delete 2 of 3.
        let removed = store.cleanupOrphans()
        XCTAssertEqual(removed, 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTmp1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTmp2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTmp.path))
    }

    func testCleanupOrphansSkipsNonTmpExtensions() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        let json = tempDir.appendingPathComponent("history.json")
        try Data().write(to: json)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 60)],
            ofItemAtPath: json.path
        )
        let removed = store.cleanupOrphans()
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    func testPruneFiltersOldEvents() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let fortyDaysAgo = now.addingTimeInterval(-40 * 24 * 60 * 60)

        let file = HistoryStore.File(events: [
            HistoryStore.Event(ts: fortyDaysAgo, service: .claude, tokensIn: 1, tokensOut: 1, costUSD: 0, modelID: "x"),
            HistoryStore.Event(ts: tenDaysAgo,   service: .claude, tokensIn: 1, tokensOut: 1, costUSD: 0, modelID: "x"),
            HistoryStore.Event(ts: oneDayAgo,    service: .claude, tokensIn: 1, tokensOut: 1, costUSD: 0, modelID: "x"),
        ])
        let pruned = store.prune(file: file, keepDays: 30, now: now)
        XCTAssertEqual(pruned.events.count, 2, "Should drop the 40-days-ago event")
    }

    func testAtomicSaveDoesNotLeaveOrphanOnSuccess() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        try store.save(HistoryStore.File(events: []))
        let entries = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        // Should be exactly history.json, no .tmp left behind.
        let tmpCount = entries.filter { $0.pathExtension == "tmp" }.count
        XCTAssertEqual(tmpCount, 0)
        XCTAssertTrue(entries.contains { $0.lastPathComponent == "history.json" })
    }

    func testQuarantineCorruptFile() throws {
        let store = try HistoryStore(directoryURL: tempDir)
        try Data("garbage".utf8).write(to: store.fileURL)
        try store.quarantineCorruptFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let entries = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.contains { $0.lastPathComponent.hasPrefix("history.broken-") })
    }
}
