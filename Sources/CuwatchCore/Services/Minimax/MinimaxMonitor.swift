import Foundation

/// Drives `MinimaxClient` on a poll loop. Reads the bearer token from a
/// `KeychainStoring` on each poll so a token replacement in Preferences is
/// picked up at the next tick without restarting the monitor.
public final class MinimaxReaderAdapter: PollOutcomeProducing {
    public enum Outcome: Sendable {
        /// Successful poll with a parsed snapshot.
        case ok(UsageSnapshot)
        /// No token in the keychain — surface as `.minimaxTokenMissing` so the
        /// onboarding row stays visible.
        case missingToken
    }

    public let client: MinimaxClient
    public let keychain: KeychainStoring
    public let tokenAccount: String

    public init(
        client: MinimaxClient,
        keychain: KeychainStoring,
        tokenAccount: String = KeychainAccount.minimaxToken
    ) {
        self.client = client
        self.keychain = keychain
        self.tokenAccount = tokenAccount
    }

    public func pollOnce(now: Date) async throws -> Outcome {
        guard let token = try keychain.get(account: tokenAccount), !token.isEmpty else {
            return .missingToken
        }
        let snapshot = try await client.fetchRemaining(token: token, now: now)
        return .ok(snapshot)
    }

    public func makeSnapshot(from outcome: Outcome, now: Date) -> UsageSnapshot? {
        if case .ok(let snapshot) = outcome { return snapshot }
        return nil
    }

    public func unconfiguredReason(from outcome: Outcome) -> UnconfiguredReason? {
        if case .missingToken = outcome { return .minimaxTokenMissing }
        return nil
    }

    public func failureReason(from error: Error) -> MonitorFailureReason {
        if let m = error as? MinimaxError {
            return m.monitorFailureReason
        }
        return .networkError
    }
}

public extension BaseServiceMonitor where Reader == MinimaxReaderAdapter {
    static func minimax(
        store: StateStore,
        client: MinimaxClient,
        keychain: KeychainStoring,
        interval: TimeInterval = Tokens.Polling.defaultIntervalSeconds,
        scheduler: SchedulerProvider = DispatchQueueMainScheduler()
    ) -> BaseServiceMonitor<MinimaxReaderAdapter> {
        BaseServiceMonitor<MinimaxReaderAdapter>(
            serviceID: .minimax,
            store: store,
            reader: MinimaxReaderAdapter(client: client, keychain: keychain),
            interval: interval,
            scheduler: scheduler
        )
    }
}
