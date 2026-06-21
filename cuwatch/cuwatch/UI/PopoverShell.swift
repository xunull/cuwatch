import SwiftUI
import CuwatchCore

/// Container that owns both the dashboard (`PopoverView`) and the Preferences
/// panel (`PreferencesView`) and animates between them.
///
/// Per DESIGN.md, the transition is a horizontal 200ms ease-out slide — the
/// Preferences panel comes in from the right, the dashboard slides out left,
/// matching the popover width exactly. Reduce Motion replaces the animation
/// with an instant cut.
struct PopoverShell: View {

    @ObservedObject var dashboardViewModel: PopoverViewModel
    @ObservedObject var preferencesViewModel: PreferencesViewModel
    var onGrantFDA: () -> Void = {}
    var onOpenCodexSetup: () -> Void = {}
    var onOpenReadmePrivacy: () -> Void = {}
    @State private var isPreferencesOpen: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = Palette.resolve(colorScheme)
        GeometryReader { proxy in
            HStack(spacing: 0) {
                PopoverView(
                    viewModel: dashboardViewModel,
                    onOpenPreferences: openPreferences,
                    onGrantFDA: onGrantFDA,
                    onOpenCodexSetup: onOpenCodexSetup,
                    onOpenReadmePrivacy: onOpenReadmePrivacy
                )
                .frame(width: Tokens.Layout.popoverWidth)
                PreferencesView(viewModel: preferencesViewModel, onBack: closePreferences)
                    .frame(width: Tokens.Layout.popoverWidth)
            }
            .frame(width: Tokens.Layout.popoverWidth * 2, alignment: .leading)
            .offset(x: isPreferencesOpen ? -Tokens.Layout.popoverWidth : 0)
            .animation(slideAnimation, value: isPreferencesOpen)
            .frame(width: Tokens.Layout.popoverWidth, alignment: .leading)
            .clipped()
        }
        .frame(width: Tokens.Layout.popoverWidth, height: proxyHeight)
        .background(palette.surface)
        .environment(\.palette, palette)
        .onAppear {
            // Keyboard shortcut wiring is best-effort here. Cmd+, fully wires
            // up once the app target lands its menu in Phase 3.
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
        isPreferencesOpen = true
        preferencesViewModel.refreshTokenState()
    }

    private func closePreferences() {
        isPreferencesOpen = false
    }
}
