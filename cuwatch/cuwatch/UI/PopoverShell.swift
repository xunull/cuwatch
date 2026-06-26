import SwiftUI
import CuwatchCore

/// Container that owns the dashboard (`PopoverView`) and two slide-in panels
/// (`PreferencesView`, `LogbookView`). Animates between them.
///
/// Per DESIGN.md, the transition is a horizontal 200ms ease-out slide — any
/// open panel comes in from the right, the dashboard slides out left,
/// matching the popover width exactly. Reduce Motion replaces the animation
/// with an instant cut.
///
/// State machine:
///   none ⇄ preferences  (footer "Preferences" link)
///   none ⇄ logbook      (footer "Logbook" link, added 2026-06-26)
struct PopoverShell: View {

    enum SlidePanel: Equatable {
        case none
        case preferences
        case logbook
    }

    @ObservedObject var dashboardViewModel: PopoverViewModel
    @ObservedObject var preferencesViewModel: PreferencesViewModel
    var onGrantFDA: () -> Void = {}
    var onOpenCodexSetup: () -> Void = {}
    var onOpenReadmePrivacy: () -> Void = {}
    /// Synchronous loader for the Codex logbook. Returns nil when no DB or
    /// empty. AppDelegate injects `{ codexLogbookReader.read() }`.
    var loadLogbook: () -> CodexLogbook? = { nil }

    @State private var activePanel: SlidePanel = .none

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = Palette.resolve(colorScheme)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                PopoverView(
                    viewModel: dashboardViewModel,
                    onOpenPreferences: openPreferences,
                    onOpenLogbook: openLogbook,
                    onGrantFDA: onGrantFDA,
                    onOpenCodexSetup: onOpenCodexSetup,
                    onOpenReadmePrivacy: onOpenReadmePrivacy
                )
                .frame(width: Tokens.Layout.popoverWidth)
                slidePanel
                    .frame(width: Tokens.Layout.popoverWidth)
            }
            .frame(width: Tokens.Layout.popoverWidth * 2, alignment: .leading)
            .offset(x: activePanel == .none ? 0 : -Tokens.Layout.popoverWidth)
            .animation(slideAnimation, value: activePanel)
            .frame(width: Tokens.Layout.popoverWidth, alignment: .leading)
            .clipped()
        }
        .frame(width: Tokens.Layout.popoverWidth, height: proxyHeight)
        .background(palette.surface)
        .environment(\.palette, palette)
    }

    @ViewBuilder
    private var slidePanel: some View {
        switch activePanel {
        case .preferences:
            PreferencesView(viewModel: preferencesViewModel, onBack: closePanel)
        case .logbook:
            LogbookView(loadLogbook: loadLogbook, onBack: closePanel)
        case .none:
            // Empty placeholder so the HStack still measures correctly while
            // the panel slides out. Color.clear keeps the layout invisible.
            Color.clear
        }
    }

    private var proxyHeight: CGFloat {
        // The popover content sizes itself with intrinsic content; we let
        // SwiftUI compute the height. This value (440) matches the maximum
        // expected popover height when all three services are configured.
        440
    }

    private var slideAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: Tokens.Motion.short)
    }

    private func openPreferences() {
        activePanel = .preferences
        preferencesViewModel.refreshTokenState()
    }

    private func openLogbook() {
        activePanel = .logbook
    }

    private func closePanel() {
        activePanel = .none
    }
}
