import Foundation
#if canImport(Combine)
import Combine
#endif

/// View-side state + actions for the Preferences panel.
///
/// Wraps `PreferencesStore` (UserDefaults) and `KeychainStoring` (tokens) and
/// exposes the minimum surface the SwiftUI views need:
/// - per-service token state (configured / not configured) + replace / remove
/// - endpoint toggle (minimaxi.com vs minimaxi.cn)
/// - polling cadence stepper with high-frequency battery warning
/// - main-service lock dropdown
/// - history retention selector + clear-history action
public final class PreferencesViewModel: ObservableObject {

    // MARK: - Public mirrors of PreferencesStore

    public let store: PreferencesStore
    public let keychain: KeychainStoring
    public let historyStore: HistoryStore?

    /// Mirror of the masked Minimax token. Updated by `refreshTokenState()`.
    /// Format: "••••••<last-4>" when present, "" when not configured.
    @Published public private(set) var minimaxTokenMasked: String = ""
    @Published public private(set) var minimaxTokenConfigured: Bool = false

    // MARK: - Init

    public init(
        store: PreferencesStore,
        keychain: KeychainStoring,
        historyStore: HistoryStore? = nil
    ) {
        self.store = store
        self.keychain = keychain
        self.historyStore = historyStore
        refreshTokenState()
    }

    // MARK: - Token state

    /// Re-read the keychain. Call after a save or removal.
    public func refreshTokenState() {
        do {
            if let raw = try keychain.get(account: KeychainAccount.minimaxToken),
               !raw.isEmpty {
                minimaxTokenConfigured = true
                minimaxTokenMasked = Self.mask(token: raw)
            } else {
                minimaxTokenConfigured = false
                minimaxTokenMasked = ""
            }
        } catch {
            minimaxTokenConfigured = false
            minimaxTokenMasked = ""
        }
    }

    /// Store a new token. Empty / whitespace-only input is rejected and
    /// `TokenSaveError.empty` is thrown so the UI can surface a hint.
    public func saveMinimaxToken(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TokenSaveError.empty }
        try keychain.set(trimmed, forAccount: KeychainAccount.minimaxToken)
        refreshTokenState()
    }

    /// Delete the stored token; UI returns the Minimax row to its onboarding
    /// "Paste API token" affordance.
    public func removeMinimaxToken() {
        try? keychain.remove(account: KeychainAccount.minimaxToken)
        refreshTokenState()
    }

    public enum TokenSaveError: Error, Equatable {
        case empty
    }

    // MARK: - Endpoint

    public func setMinimaxEndpoint(_ endpoint: MinimaxEndpoint) {
        store.minimaxEndpoint = endpoint
    }

    // MARK: - Polling cadence

    public func setPollInterval(_ seconds: TimeInterval) {
        store.pollIntervalSeconds = seconds
    }

    public func setMainServiceLock(_ lock: MainServiceLock) {
        store.mainServiceLock = lock
    }

    // MARK: - History

    public func setHistoryRetentionDays(_ days: Int) {
        store.historyRetentionDays = days
    }

    /// Wipe `history.json`. Used by the "Clear history" danger button after
    /// confirmation in the UI. Returns true when the file was deleted (or
    /// already absent).
    @discardableResult
    public func clearHistory() throws -> Bool {
        guard let historyStore else { return false }
        try historyStore.save(HistoryStore.File(version: 1, events: []))
        return true
    }

    /// Open the Application Support directory in Finder. The UI surface for
    /// this is a "Reveal data" link in the Data & Privacy section.
    public func applicationSupportURL() -> URL? {
        try? HistoryStore.defaultDirectoryURL()
    }

    // MARK: - Helpers

    static func mask(token raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let last4 = raw.suffix(4)
        return "••••••\(last4)"
    }
}
