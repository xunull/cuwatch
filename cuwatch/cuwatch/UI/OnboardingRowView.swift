import SwiftUI
import CuwatchCore

/// Per-service onboarding row used in States A / C / E.
///
/// The CTA copy and tap action are different per service because each has a
/// different auth model (filesystem vs filesystem-CLI vs bearer token).
/// Tap actions are surfaced via callbacks so AppDelegate can wire them to the
/// system (open System Settings → FDA, open README, slide to Preferences).
struct OnboardingRowView: View {

    let service: ServiceID
    let reason: UnconfiguredReason
    let palette: Palette

    /// Open the macOS System Settings → Privacy & Security → Full Disk Access page.
    var onGrantFDA: () -> Void = {}
    /// Open the README's Codex setup section in the user's browser.
    var onOpenCodexSetup: () -> Void = {}
    /// Slide to Preferences so the user can paste a Minimax token.
    var onOpenMinimaxPreferences: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s12) {
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                Text(service.displayLabel)
                    .labelStyle()
                    .foregroundColor(palette.brass)
                Button(action: action) {
                    HStack(spacing: Tokens.Space.s4) {
                        Text(ctaLabel)
                            .font(PopoverFont.value())
                            .foregroundColor(palette.inkMute)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(palette.inkDim)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, Tokens.Space.s12)
    }

    private var ctaLabel: String {
        switch reason {
        case .missingFullDiskAccess: return "Grant Full Disk Access"
        case .codexNotInstalled:     return "Install codex CLI"
        case .codexNotAuthenticated: return "Run `codex auth login`"
        case .minimaxTokenMissing:   return "Paste API token"
        }
    }

    private func action() {
        switch reason {
        case .missingFullDiskAccess: onGrantFDA()
        case .codexNotInstalled, .codexNotAuthenticated: onOpenCodexSetup()
        case .minimaxTokenMissing: onOpenMinimaxPreferences()
        }
    }
}
