import Foundation

/// One of the three AI services cuwatch tracks.
public enum ServiceID: String, CaseIterable, Codable, Sendable, Hashable {
    case claude = "claude_code"
    case codex = "codex"
    case minimax = "minimax"

    /// The brass-label form rendered in the popover ("CLAUDE", "CODEX", "MINIMAX").
    public var displayLabel: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex: return "CODEX"
        case .minimax: return "MINIMAX"
        }
    }

    /// Auth model. Each service has a different mechanism.
    public var authModel: AuthModel {
        switch self {
        case .claude: return .filesystemRead(path: "~/.claude/projects/")
        case .codex: return .filesystemRead(path: "~/.codex/")
        case .minimax: return .bearerToken
        }
    }

    /// Onboarding-row dim text shown when this service is not configured / not available.
    /// Per /plan-eng-review D1, each service has a different setup CTA.
    public var onboardingCTA: String {
        switch self {
        case .claude: return "Grant Full Disk Access"
        case .codex: return "Install codex CLI"
        case .minimax: return "Paste API token"
        }
    }
}

/// What "configuring" a service actually means.
public enum AuthModel: Equatable, Sendable {
    /// Service is read from a local filesystem path. No token required.
    /// User typically needs to grant TCC permission, install a CLI, or authenticate via another tool.
    case filesystemRead(path: String)
    /// Service requires the user to paste a bearer token, which we store in Keychain.
    case bearerToken
}
