import XCTest
@testable import CuwatchCore

final class KeychainStoreTests: XCTestCase {

    // MARK: - InMemoryKeychainStore

    func testInMemorySetGetRoundTrip() throws {
        let store = InMemoryKeychainStore()
        try store.set("mxp_abcdef", forAccount: KeychainAccount.minimaxToken)
        XCTAssertEqual(try store.get(account: KeychainAccount.minimaxToken), "mxp_abcdef")
    }

    func testInMemoryGetAbsentReturnsNil() throws {
        let store = InMemoryKeychainStore()
        XCTAssertNil(try store.get(account: KeychainAccount.minimaxToken))
    }

    func testInMemoryRemoveDeletesEntry() throws {
        let store = InMemoryKeychainStore()
        try store.set("token", forAccount: KeychainAccount.minimaxToken)
        try store.remove(account: KeychainAccount.minimaxToken)
        XCTAssertNil(try store.get(account: KeychainAccount.minimaxToken))
    }

    func testInMemorySetOverwritesPriorValue() throws {
        let store = InMemoryKeychainStore()
        try store.set("first", forAccount: KeychainAccount.minimaxToken)
        try store.set("second", forAccount: KeychainAccount.minimaxToken)
        XCTAssertEqual(try store.get(account: KeychainAccount.minimaxToken), "second")
    }

    func testInMemoryRemoveAbsentIsNoOp() throws {
        let store = InMemoryKeychainStore()
        XCTAssertNoThrow(try store.remove(account: "never-set"))
    }

    // MARK: - Real Keychain (macOS only)

    #if canImport(Security)

    /// Each test uses a unique service id to avoid colliding with itself across
    /// runs or with prod cuwatch on the same machine.
    private func uniqueStore() -> KeychainStore {
        KeychainStore(service: "cuwatch.tests.\(UUID().uuidString)")
    }

    func testRealKeychainRoundTrip() throws {
        let store = uniqueStore()
        defer { try? store.remove(account: "test_account") }
        try store.set("hello-keychain", forAccount: "test_account")
        XCTAssertEqual(try store.get(account: "test_account"), "hello-keychain")
    }

    func testRealKeychainOverwriteReplaces() throws {
        let store = uniqueStore()
        defer { try? store.remove(account: "tok") }
        try store.set("v1", forAccount: "tok")
        try store.set("v2", forAccount: "tok")
        XCTAssertEqual(try store.get(account: "tok"), "v2")
    }

    func testRealKeychainRemoveDeletesEntry() throws {
        let store = uniqueStore()
        try store.set("v1", forAccount: "tok")
        try store.remove(account: "tok")
        XCTAssertNil(try store.get(account: "tok"))
    }

    func testRealKeychainGetAbsentReturnsNil() throws {
        let store = uniqueStore()
        XCTAssertNil(try store.get(account: "never-set"))
    }

    #endif
}
