import Foundation
#if canImport(Combine)
import Combine
#endif

/// The shared, mutable, observable application state.
///
/// All three `ServiceMonitor`s publish into a single `StateStore`. The UI layer
/// (PopoverViewModel, MenuBarDial) observes via `ObservableObject` and re-renders.
///
/// We target macOS 12+ (per plan Constraints), so the modern `@Observable` macro
/// is off the table — it's macOS 14+. `ObservableObject` is the right tool here
/// and works back to macOS 10.15.
///
/// The `mainService` election rule (per plan + /plan-eng-review D1, semantics
/// inverted 2026-06-21 alongside the remaining → used reversal):
/// - Among services with `activeSnapshot != nil` (i.e. successfully polled at least once
///   and not in unconfigured / network-failure state):
///   pick the one with the **highest** `usedFraction` (the most constrained budget).
/// - Ties broken by ServiceID order: claude < codex < minimax (stable).
/// - If none qualify, `mainService` is `nil` and the menu bar dial is neutral grey.
///
/// Unconfigured / failed services are excluded from the election so their stale or
/// missing data doesn't drive the dial.
public final class StateStore: ObservableObject {

    /// Latest successful snapshot per service. Missing entries → not yet polled / not configured.
    @Published public private(set) var snapshots: [ServiceID: UsageSnapshot] = [:]

    /// Current operating state of each service monitor.
    @Published public private(set) var monitorStates: [ServiceID: MonitorState] = [
        .claude: .idle,
        .codex: .idle,
        .minimax: .idle,
    ]

    public init() {}

    /// Publish a new snapshot. Call from monitor on successful poll.
    public func publish(snapshot: UsageSnapshot) {
        snapshots[snapshot.service] = snapshot
    }

    /// Update monitor state without changing snapshots.
    public func update(monitorState: MonitorState, for service: ServiceID) {
        monitorStates[service] = monitorState
    }

    /// Clear stored snapshot for a service. Used when user removes a token or revokes FDA.
    public func clearSnapshot(for service: ServiceID) {
        snapshots[service] = nil
    }

    /// The "main" service whose state drives the menu bar dial + popover header readout.
    ///
    /// Returns `nil` when zero services have publishable snapshots — the dial then
    /// shows neutral grey (per plan State A onboarding).
    public var mainService: ServiceID? {
        let eligible = ServiceID.allCases.filter { service in
            guard snapshots[service] != nil else { return false }
            switch monitorStates[service] ?? .idle {
            case .idle, .unconfigured:
                return false
            case .active, .backingOff:
                // backingOff still has a stale snapshot but it's the last good read, so keep it.
                return true
            }
        }
        let highestUsed = eligible.max { a, b in
            let aFrac = snapshots[a]?.usedFraction ?? 0.0
            let bFrac = snapshots[b]?.usedFraction ?? 0.0
            if aFrac == bFrac {
                // Tie-break by ServiceID ordering for stability — we want the
                // EARLIER-indexed service to win on equal usage, so flip the
                // inequality vs min(): a < b means a stays as the running max.
                return ServiceID.allCases.firstIndex(of: a)! > ServiceID.allCases.firstIndex(of: b)!
            }
            return aFrac < bFrac
        }
        return highestUsed
    }

    /// The color state used to drive the menu bar dial arc + needle color.
    /// Neutral grey when no service is publishable.
    public var dialColorState: DialColorState {
        guard let main = mainService, let snapshot = snapshots[main] else {
            return .neutralGrey
        }
        switch snapshot.colorState {
        case .normal: return .brass
        case .warn: return .burntOrange
        case .danger: return .oxidizedRed
        }
    }
}

/// What the menu bar dial visually communicates right now.
public enum DialColorState: Equatable, Sendable {
    case neutralGrey
    case brass
    case burntOrange
    case oxidizedRed
}
