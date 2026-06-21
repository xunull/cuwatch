import Foundation
#if canImport(Security)
import Security
#endif

/// A small CRUD wrapper around macOS Keychain generic-password items.
///
/// Used by cuwatch to store the Minimax bearer token (and later anything else
/// that needs at-rest secret storage). One `KeychainStore` instance owns one
/// "service" string in keychain terms, and stores key/value pairs under it.
///
/// The default `service` value for production use is `cuwatch.tokens` so all
/// cuwatch secrets live in one logical bucket.
///
/// Thread-safety: Apple's keychain APIs are thread-safe. This wrapper itself
/// holds no mutable state.
public protocol KeychainStoring: AnyObject, Sendable {
    /// Store (or replace) a UTF-8 string under `account`.
    func set(_ value: String, forAccount account: String) throws

    /// Retrieve the UTF-8 string for `account`. Returns nil when absent.
    func get(account: String) throws -> String?

    /// Remove the entry for `account`. No-op if absent.
    func remove(account: String) throws
}

public enum KeychainError: Error, Equatable, Sendable {
    /// Raw OSStatus code from Security framework. Useful for diagnostics
    /// (`errSecDuplicateItem`, `errSecItemNotFound`, etc).
    case osStatus(Int32, message: String?)
    /// Value couldn't be encoded as UTF-8 (shouldn't happen for strings).
    case encodingFailed
}

#if canImport(Security)

/// Real-Keychain-backed implementation. Production path.
public final class KeychainStore: KeychainStoring, @unchecked Sendable {

    public let service: String

    public init(service: String = "cuwatch.tokens") {
        self.service = service
    }

    public func set(_ value: String, forAccount account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Try update first — cheaper than a delete+add round-trip if the item exists.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus, message: Self.message(for: updateStatus))
        }

        // Not found — add new.
        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus, message: Self.message(for: addStatus))
        }
    }

    public func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status, message: Self.message(for: status))
        }
    }

    public func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.osStatus(status, message: Self.message(for: status))
        }
    }

    /// Best-effort human-readable error message for an OSStatus.
    private static func message(for status: OSStatus) -> String? {
        SecCopyErrorMessageString(status, nil) as String?
    }
}

#endif // canImport(Security)

// MARK: - In-memory mock

/// An in-memory store conforming to `KeychainStoring`. Used by tests so we don't
/// hit the real system keychain.
public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "cuwatch.InMemoryKeychainStore")
    private var items: [String: String] = [:]

    public init() {}

    public func set(_ value: String, forAccount account: String) throws {
        queue.sync { items[account] = value }
    }

    public func get(account: String) throws -> String? {
        queue.sync { items[account] }
    }

    public func remove(account: String) throws {
        queue.sync { _ = items.removeValue(forKey: account) }
    }

    public var snapshot: [String: String] {
        queue.sync { items }
    }
}

// MARK: - Account constants

public enum KeychainAccount {
    /// Minimax bearer token.
    public static let minimaxToken = "minimax.bearer_token"
}
