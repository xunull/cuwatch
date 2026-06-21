import XCTest
@testable import CuwatchCore

final class PreferencesStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cuwatch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testInitialValuesMatchDefaults() {
        let store = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store.minimaxEndpoint, .global)
        XCTAssertEqual(store.pollIntervalSeconds, Tokens.Polling.defaultIntervalSeconds)
        XCTAssertEqual(store.historyRetentionDays, 30)
        XCTAssertEqual(store.mainServiceLock, .auto)
    }

    func testDefaultsPersistAcrossInstances() {
        let store1 = PreferencesStore(userDefaults: defaults)
        store1.minimaxEndpoint = .china
        store1.pollIntervalSeconds = 60
        store1.historyRetentionDays = 90
        store1.mainServiceLock = .codex

        let store2 = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store2.minimaxEndpoint, .china)
        XCTAssertEqual(store2.pollIntervalSeconds, 60)
        XCTAssertEqual(store2.historyRetentionDays, 90)
        XCTAssertEqual(store2.mainServiceLock, .codex)
    }

    // MARK: - Poll interval clamping

    func testPollIntervalClampsTooLow() {
        let store = PreferencesStore(userDefaults: defaults)
        store.pollIntervalSeconds = 5
        XCTAssertEqual(store.pollIntervalSeconds, Tokens.Polling.minIntervalSeconds)
    }

    func testPollIntervalClampsTooHigh() {
        let store = PreferencesStore(userDefaults: defaults)
        store.pollIntervalSeconds = 999
        XCTAssertEqual(store.pollIntervalSeconds, Tokens.Polling.maxIntervalSeconds)
    }

    func testPollIntervalAcceptsValidValue() {
        let store = PreferencesStore(userDefaults: defaults)
        store.pollIntervalSeconds = 60
        XCTAssertEqual(store.pollIntervalSeconds, 60)
    }

    func testHighFrequencyWarningThreshold() {
        let store = PreferencesStore(userDefaults: defaults)
        store.pollIntervalSeconds = 10
        XCTAssertTrue(store.isPollIntervalAtHighFrequencyWarningThreshold)
        store.pollIntervalSeconds = 30
        XCTAssertFalse(store.isPollIntervalAtHighFrequencyWarningThreshold)
    }

    // MARK: - History retention normalization

    func testHistoryRetentionZeroFallsBackToDefault() {
        let store = PreferencesStore(userDefaults: defaults)
        store.historyRetentionDays = 0
        XCTAssertEqual(store.historyRetentionDays, 30)
    }

    func testHistoryRetentionNegativeBecomesForever() {
        let store = PreferencesStore(userDefaults: defaults)
        store.historyRetentionDays = -5
        XCTAssertEqual(store.historyRetentionDays, -1)
    }

    func testHistoryRetentionPositiveStays() {
        let store = PreferencesStore(userDefaults: defaults)
        store.historyRetentionDays = 90
        XCTAssertEqual(store.historyRetentionDays, 90)
    }

    // MARK: - Reset

    func testResetWipesAllPersistedValues() {
        let store = PreferencesStore(userDefaults: defaults)
        store.minimaxEndpoint = .china
        store.pollIntervalSeconds = 60
        store.historyRetentionDays = 90
        store.mainServiceLock = .minimax

        store.resetToDefaults()

        XCTAssertEqual(store.minimaxEndpoint, .global)
        XCTAssertEqual(store.pollIntervalSeconds, Tokens.Polling.defaultIntervalSeconds)
        XCTAssertEqual(store.historyRetentionDays, 30)
        XCTAssertEqual(store.mainServiceLock, .auto)

        let fresh = PreferencesStore(userDefaults: defaults)
        XCTAssertEqual(fresh.minimaxEndpoint, .global)
    }

    // MARK: - MainServiceLock

    func testMainServiceLockMapsToServiceID() {
        XCTAssertNil(MainServiceLock.auto.serviceID)
        XCTAssertEqual(MainServiceLock.claude.serviceID, .claude)
        XCTAssertEqual(MainServiceLock.codex.serviceID, .codex)
        XCTAssertEqual(MainServiceLock.minimax.serviceID, .minimax)
    }
}
