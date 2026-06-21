import XCTest
@testable import CuwatchCore

final class PreferencesViewModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: InMemoryKeychainStore!
    private var store: PreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "cuwatch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        keychain = InMemoryKeychainStore()
        store = PreferencesStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Token state

    func testInitiallyTokenIsNotConfigured() {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        XCTAssertFalse(vm.minimaxTokenConfigured)
        XCTAssertEqual(vm.minimaxTokenMasked, "")
    }

    func testSavingTokenUpdatesMaskedView() throws {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        try vm.saveMinimaxToken("mxp_abcd1234")
        XCTAssertTrue(vm.minimaxTokenConfigured)
        XCTAssertEqual(vm.minimaxTokenMasked, "••••••1234")
    }

    func testSavingEmptyTokenThrows() {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        XCTAssertThrowsError(try vm.saveMinimaxToken("")) { err in
            XCTAssertEqual(err as? PreferencesViewModel.TokenSaveError, .empty)
        }
        XCTAssertThrowsError(try vm.saveMinimaxToken("   ")) { err in
            XCTAssertEqual(err as? PreferencesViewModel.TokenSaveError, .empty)
        }
        XCTAssertFalse(vm.minimaxTokenConfigured)
    }

    func testRemovingTokenClearsState() throws {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        try vm.saveMinimaxToken("mxp_abcd")
        vm.removeMinimaxToken()
        XCTAssertFalse(vm.minimaxTokenConfigured)
        XCTAssertEqual(vm.minimaxTokenMasked, "")
    }

    func testTokenSavingTrimsWhitespace() throws {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        try vm.saveMinimaxToken("  mxp_abcd\n")
        let stored = try keychain.get(account: KeychainAccount.minimaxToken)
        XCTAssertEqual(stored, "mxp_abcd")
    }

    // MARK: - Endpoint

    func testEndpointWriteThroughToStore() {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        vm.setMinimaxEndpoint(.china)
        XCTAssertEqual(store.minimaxEndpoint, .china)
    }

    // MARK: - Poll interval

    func testPollIntervalWriteThroughToStore() {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        vm.setPollInterval(60)
        XCTAssertEqual(store.pollIntervalSeconds, 60)
    }

    // MARK: - Mask helper

    func testMaskTokenShowsLast4() {
        XCTAssertEqual(PreferencesViewModel.mask(token: "abcdef1234"), "••••••1234")
        XCTAssertEqual(PreferencesViewModel.mask(token: "abc"), "••••••abc")
        XCTAssertEqual(PreferencesViewModel.mask(token: ""), "")
    }

    // MARK: - History clear

    func testClearHistoryWithoutStoreReturnsFalse() throws {
        let vm = PreferencesViewModel(store: store, keychain: keychain)
        let result = try vm.clearHistory()
        XCTAssertFalse(result)
    }

    func testClearHistoryWritesEmptyFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuwatch-prefvm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let history = try HistoryStore(directoryURL: tempDir)
        let event = HistoryStore.Event(
            ts: Date(), service: .claude,
            tokensIn: 1000, tokensOut: 500, costUSD: 0.42,
            modelID: "claude-opus-4-7"
        )
        try history.save(HistoryStore.File(events: [event]))

        let vm = PreferencesViewModel(store: store, keychain: keychain, historyStore: history)
        XCTAssertTrue(try vm.clearHistory())

        let reloaded = try history.load()
        XCTAssertEqual(reloaded.events.count, 0)
    }
}
