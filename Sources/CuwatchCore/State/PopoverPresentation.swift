import Foundation

/// What the popover should currently render — the five States from the plan.
///
/// Computed deterministically from the monitor / snapshot state map so a
/// re-render with the same inputs always yields the same UI shape. This means
/// view tests can be pure and the SwiftUI render side does no decision-making.
public enum PopoverPresentation: Equatable, Sendable {

    /// State A — none of the three services is configured yet.
    /// Show three per-service onboarding rows + AWAITING SETUP header.
    case onboardingAllServices

    /// State B — at least Claude is blocked on TCC FDA permission.
    /// Show the full-width FDA card replacing the Claude row; the other two
    /// rows render normally (or in their own onboarding state).
    case claudeFDABlocked(otherStates: [ServiceID: ServiceTileState])

    /// State C — some services are active and some need onboarding. The
    /// dashboard renders normally for active services; onboarding row swaps in
    /// for unconfigured ones.
    case partiallyConfigured(states: [ServiceID: ServiceTileState])

    /// State D — all three monitors are configured but at least one is in
    /// a `.backingOff` / network-failure state; the active ones render normal,
    /// the failed one renders dim.
    case allConfiguredWithDegradation(states: [ServiceID: ServiceTileState])

    /// State E — every service is unconfigured AND failing. The popover header
    /// shows NO DATA; each row tells the truth about its own failure mode.
    case allServicesDown(states: [ServiceID: ServiceTileState])

    /// State F — normal: everything is active and publishing.
    case normalDashboard

    // MARK: - Derivation

    /// Decide which of the five presentations to use given the current monitor
    /// state map. Snapshot map is consulted only to distinguish "has data" vs
    /// "has been polled but is now stale" cases.
    public static func resolve(
        monitorStates: [ServiceID: MonitorState],
        snapshots: [ServiceID: UsageSnapshot]
    ) -> PopoverPresentation {

        let tileStates: [ServiceID: ServiceTileState] = ServiceID.allCases.reduce(into: [:]) { acc, service in
            let monitor = monitorStates[service] ?? .idle
            let snapshot = snapshots[service]
            acc[service] = ServiceTileState.derive(monitor: monitor, snapshot: snapshot)
        }

        let allUnconfigured = ServiceID.allCases.allSatisfy { id in
            if case .unconfigured = tileStates[id] { return true }
            return false
        }
        if allUnconfigured {
            return .onboardingAllServices
        }

        // Claude FDA blocked? It owns its own dedicated State B card.
        if case .unconfigured(.missingFullDiskAccess) = tileStates[.claude] {
            var others = tileStates
            others.removeValue(forKey: .claude)
            return .claudeFDABlocked(otherStates: others)
        }

        let activeCount = ServiceID.allCases.filter { id in
            if case .active = tileStates[id] { return true }
            return false
        }.count
        let unconfiguredCount = ServiceID.allCases.filter { id in
            if case .unconfigured = tileStates[id] { return true }
            return false
        }.count
        let failedCount = ServiceID.allCases.filter { id in
            if case .backingOff = tileStates[id] { return true }
            return false
        }.count

        // All three down (some failing, some unconfigured, or any mix where
        // zero are publishing data).
        if activeCount == 0 {
            return .allServicesDown(states: tileStates)
        }

        if unconfiguredCount > 0 {
            return .partiallyConfigured(states: tileStates)
        }

        if failedCount > 0 {
            return .allConfiguredWithDegradation(states: tileStates)
        }

        return .normalDashboard
    }
}

/// What a single service row is doing in the popover. View code uses this to
/// pick between the normal progress-bar row, an onboarding-CTA row, the
/// network-failure dim row, etc.
public enum ServiceTileState: Equatable, Sendable {
    /// Service is publishing live data; render the normal progress-bar row.
    case active(UsageSnapshot)
    /// Service has a stale snapshot but the latest poll failed; dim + retry note.
    case backingOff(stale: UsageSnapshot?, reason: MonitorFailureReason, nextRetryIn: TimeInterval)
    /// Service needs the user to do something to make data flow. The reason
    /// drives the per-service CTA copy in the onboarding row.
    case unconfigured(UnconfiguredReason)
    /// Monitor hasn't been started yet (cold launch, mid-restart).
    case idle

    public static func derive(monitor: MonitorState, snapshot: UsageSnapshot?) -> ServiceTileState {
        switch monitor {
        case .idle:
            return .idle
        case .active:
            if let snapshot { return .active(snapshot) }
            // No snapshot but the monitor is active — this is the post-start,
            // pre-first-publish window; treat as idle until data arrives.
            return .idle
        case .backingOff(let reason, let nextRetry, _):
            return .backingOff(stale: snapshot, reason: reason, nextRetryIn: nextRetry)
        case .unconfigured(let reason):
            return .unconfigured(reason)
        }
    }
}
