import Foundation
#if canImport(Combine)
import Combine
#endif

/// Persistent backing for the non-secret user preferences.
///
/// Secrets (Minimax bearer token) live in `KeychainStore`; everything else
/// (endpoint, polling cadence, history retention, main-service lock) lives
/// here in `UserDefaults`. The store is `ObservableObject` so the
/// `PreferencesView` re-renders as the user toggles things; downstream
/// consumers (the Minimax monitor that wants to know the endpoint, the
/// scheduling layer that wants to know the polling cadence) subscribe to
/// the `@Published` properties directly.
///
/// Defaults match the plan + DESIGN.md decisions and are clamped on set so
/// "polling cadence 0" or "history retention -3 days" can never reach disk.
public final class PreferencesStore: ObservableObject {

    // MARK: - Storage keys

    public enum Keys {
        public static let minimaxEndpoint = "cuwatch.minimax.endpoint"
        public static let pollIntervalSeconds = "cuwatch.poll.interval_seconds"
        public static let historyRetentionDays = "cuwatch.history.retention_days"
        public static let mainServiceLock = "cuwatch.main_service.lock"
        public static let languagePreference = "cuwatch.language.preference"
    }

    public enum Defaults {
        public static let minimaxEndpoint: MinimaxEndpoint = .global
        public static let pollIntervalSeconds: TimeInterval = Tokens.Polling.defaultIntervalSeconds
        public static let historyRetentionDays: Int = 30
        public static let mainServiceLock: MainServiceLock = .auto
        public static let languagePreference: LanguagePreference = .system
    }

    /// Allowed history retention buckets shown in the picker.
    public static let historyRetentionOptions: [Int] = [7, 30, 90, -1]

    // MARK: - Published state

    @Published public var minimaxEndpoint: MinimaxEndpoint {
        didSet {
            guard minimaxEndpoint != oldValue else { return }
            userDefaults.set(minimaxEndpoint.rawValue, forKey: Keys.minimaxEndpoint)
        }
    }

    /// Poll interval, in seconds. Clamped to [10, 300] on set.
    @Published public var pollIntervalSeconds: TimeInterval {
        didSet {
            let clamped = Self.clampPollInterval(pollIntervalSeconds)
            if clamped != pollIntervalSeconds {
                pollIntervalSeconds = clamped
                return
            }
            guard pollIntervalSeconds != oldValue else { return }
            userDefaults.set(pollIntervalSeconds, forKey: Keys.pollIntervalSeconds)
        }
    }

    /// `-1` means "retain forever". Other values must be > 0.
    @Published public var historyRetentionDays: Int {
        didSet {
            let normalized = Self.normalizeHistoryRetention(historyRetentionDays)
            if normalized != historyRetentionDays {
                historyRetentionDays = normalized
                return
            }
            guard historyRetentionDays != oldValue else { return }
            userDefaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays)
        }
    }

    @Published public var mainServiceLock: MainServiceLock {
        didSet {
            guard mainServiceLock != oldValue else { return }
            userDefaults.set(mainServiceLock.rawValue, forKey: Keys.mainServiceLock)
        }
    }

    /// UI language preference. `.system` follows the macOS preferred locale.
    /// `.en` / `.zhHans` force the corresponding locale regardless of system.
    /// Drives `effectiveLocale`, which `AppDelegate` injects into the SwiftUI
    /// environment for live switching (no restart). Added 2026-06-26 i18n.
    @Published public var languagePreference: LanguagePreference {
        didSet {
            guard languagePreference != oldValue else { return }
            userDefaults.set(languagePreference.rawValue, forKey: Keys.languagePreference)
        }
    }

    /// Locale to inject into the SwiftUI environment. `.system` → returns the
    /// process's current locale; explicit choices return a fresh `Locale`.
    public var effectiveLocale: Locale {
        switch languagePreference {
        case .system:
            return Locale.current
        case .en:
            return Locale(identifier: "en")
        case .zhHans:
            return Locale(identifier: "zh-Hans")
        }
    }

    public let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Endpoint.
        if let raw = userDefaults.string(forKey: Keys.minimaxEndpoint),
           let value = MinimaxEndpoint(rawValue: raw) {
            self.minimaxEndpoint = value
        } else {
            self.minimaxEndpoint = Defaults.minimaxEndpoint
        }

        // Poll interval.
        let storedInterval = userDefaults.double(forKey: Keys.pollIntervalSeconds)
        if storedInterval > 0 {
            self.pollIntervalSeconds = Self.clampPollInterval(storedInterval)
        } else {
            self.pollIntervalSeconds = Defaults.pollIntervalSeconds
        }

        // History retention.
        if userDefaults.object(forKey: Keys.historyRetentionDays) != nil {
            self.historyRetentionDays = Self.normalizeHistoryRetention(
                userDefaults.integer(forKey: Keys.historyRetentionDays)
            )
        } else {
            self.historyRetentionDays = Defaults.historyRetentionDays
        }

        // Main service lock.
        if let raw = userDefaults.string(forKey: Keys.mainServiceLock),
           let value = MainServiceLock(rawValue: raw) {
            self.mainServiceLock = value
        } else {
            self.mainServiceLock = Defaults.mainServiceLock
        }

        // Language preference.
        if let raw = userDefaults.string(forKey: Keys.languagePreference),
           let value = LanguagePreference(rawValue: raw) {
            self.languagePreference = value
        } else {
            self.languagePreference = Defaults.languagePreference
        }
    }

    // MARK: - Reset

    /// Wipe everything cuwatch wrote into the supplied UserDefaults. Used by
    /// "Reset preferences" affordance (UI surface to be added in a later task)
    /// and by tests so they start from a clean slate.
    public func resetToDefaults() {
        userDefaults.removeObject(forKey: Keys.minimaxEndpoint)
        userDefaults.removeObject(forKey: Keys.pollIntervalSeconds)
        userDefaults.removeObject(forKey: Keys.historyRetentionDays)
        userDefaults.removeObject(forKey: Keys.mainServiceLock)
        userDefaults.removeObject(forKey: Keys.languagePreference)
        minimaxEndpoint = Defaults.minimaxEndpoint
        pollIntervalSeconds = Defaults.pollIntervalSeconds
        historyRetentionDays = Defaults.historyRetentionDays
        mainServiceLock = Defaults.mainServiceLock
        languagePreference = Defaults.languagePreference
    }

    // MARK: - Helpers

    /// Clamp the polling interval to the allowed [10, 300] range. Anything
    /// outside collapses to the nearest edge.
    public static func clampPollInterval(_ value: TimeInterval) -> TimeInterval {
        max(Tokens.Polling.minIntervalSeconds,
            min(Tokens.Polling.maxIntervalSeconds, value))
    }

    /// Normalize history retention: positive values stay; 0 collapses to
    /// default (30); negative values collapse to "retain forever" (-1).
    public static func normalizeHistoryRetention(_ value: Int) -> Int {
        if value == 0 { return Defaults.historyRetentionDays }
        if value < 0 { return -1 }
        return value
    }

    public var isPollIntervalAtHighFrequencyWarningThreshold: Bool {
        pollIntervalSeconds <= Tokens.Polling.highFrequencyWarningThresholdSeconds
    }
}

/// Which service the menu bar dial follows. `.auto` means "lowest remaining %
/// across active services"; an explicit service pin locks the dial to that one.
public enum MainServiceLock: String, CaseIterable, Equatable, Sendable, Codable {
    case auto
    case claude
    case codex
    case minimax

    public var serviceID: ServiceID? {
        switch self {
        case .auto: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .minimax: return .minimax
        }
    }

    public var displayLabel: String {
        switch self {
        case .auto: return "Auto (lowest %)"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .minimax: return "Minimax"
        }
    }
}

/// UI language preference. `.system` = follow macOS preferred locale.
/// `.en` / `.zhHans` = force the corresponding locale regardless of system.
/// Added 2026-06-26 i18n. See `docs/i18n-zh-hans-design.md`.
public enum LanguagePreference: String, CaseIterable, Equatable, Sendable, Codable {
    case system
    case en
    case zhHans = "zh-Hans"
}
