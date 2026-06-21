import SwiftUI
import CuwatchCore

/// The dashboard popover content. Picks between five layouts based on
/// `viewModel.presentation` (State A-F per the plan).
///
/// Layout (per DESIGN.md):
/// - 340pt wide, 24pt outer padding, hairline borders between sections.
/// - Header (~80pt): big readout left, label below, 48pt mini dial right.
/// - Three service rows separated by hairlines (the FDA-blocked variant
///   replaces the Claude row with a full-width card; the all-down variant
///   shows three onboarding-style rows + NO DATA header).
/// - Footer (11pt): last-update time + Preferences link.
struct PopoverView: View {

    @ObservedObject var viewModel: PopoverViewModel
    var onOpenPreferences: () -> Void = {}
    var onGrantFDA: () -> Void = {}
    var onOpenCodexSetup: () -> Void = {}
    var onOpenReadmePrivacy: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.resolve(colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(palette: palette)
                .padding(.bottom, Tokens.Space.s24)
                .overlay(alignment: .bottom) { hairline(palette: palette) }

            content(palette: palette)

            footer(palette: palette)
                .padding(.top, Tokens.Space.s16)
                .overlay(alignment: .top) { hairline(palette: palette) }
        }
        .padding(Tokens.Space.s24)
        .frame(width: Tokens.Layout.popoverWidth, alignment: .topLeading)
        .background(palette.surface)
        .environment(\.palette, palette)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(palette: Palette) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                Text(readoutText)
                    .font(PopoverFont.display())
                    .foregroundColor(palette.ink)
                Text(headerLabel)
                    .labelStyle()
                    .foregroundColor(headerLabelColor(palette: palette))
            }
            Spacer()
            MiniDialView(
                fraction: mainFraction,
                colorState: viewModel.dialColorState,
                palette: palette
            )
        }
    }

    private var readoutText: String {
        switch viewModel.presentation {
        case .onboardingAllServices, .allServicesDown:
            return "—%"
        default:
            guard let main = viewModel.mainService,
                  let snapshot = viewModel.snapshots[main] else {
                return "—%"
            }
            let pct = Int((snapshot.usedFraction * 100).rounded())
            return "\(pct)%"
        }
    }

    private var headerLabel: String {
        switch viewModel.presentation {
        case .onboardingAllServices:
            return "AWAITING SETUP"
        case .allServicesDown:
            return "NO DATA"
        default:
            guard let main = viewModel.mainService else { return "AWAITING SETUP" }
            let window: String
            switch viewModel.snapshots[main]?.window {
            case .sessionWindow5h: window = "5h window"
            case .weekly: window = "weekly"
            case .tokenBudget: window = "token plan"
            case .none: window = ""
            }
            return "\(main.displayLabel) · \(window)"
        }
    }

    private func headerLabelColor(palette: Palette) -> SwiftUI.Color {
        switch viewModel.dialColorState {
        case .burntOrange: return palette.warn
        case .oxidizedRed: return palette.danger
        default: return palette.brass
        }
    }

    private var mainFraction: Double {
        guard let main = viewModel.mainService,
              let snapshot = viewModel.snapshots[main] else {
            return 0.0
        }
        return snapshot.usedFraction
    }

    // MARK: - Content

    @ViewBuilder
    private func content(palette: Palette) -> some View {
        switch viewModel.presentation {
        case .onboardingAllServices:
            VStack(spacing: 0) {
                ForEach(Array(ServiceID.allCases.enumerated()), id: \.element) { index, service in
                    rowView(
                        for: service,
                        tileState: .unconfigured(defaultReason(for: service)),
                        palette: palette
                    )
                    if index < ServiceID.allCases.count - 1 {
                        hairline(palette: palette)
                    }
                }
            }
        case .claudeFDABlocked(let otherStates):
            VStack(spacing: 0) {
                TCCFDACardView(
                    palette: palette,
                    onOpenSystemSettings: onGrantFDA,
                    onOpenReadmePrivacy: onOpenReadmePrivacy
                )
                .padding(.top, Tokens.Space.s8)
                hairline(palette: palette)
                ForEach([ServiceID.codex, .minimax], id: \.self) { service in
                    if let state = otherStates[service] {
                        rowView(for: service, tileState: state, palette: palette)
                        if service == .codex { hairline(palette: palette) }
                    }
                }
            }
        case .partiallyConfigured(let states),
             .allConfiguredWithDegradation(let states),
             .allServicesDown(let states):
            VStack(spacing: 0) {
                ForEach(Array(ServiceID.allCases.enumerated()), id: \.element) { index, service in
                    rowView(
                        for: service,
                        tileState: states[service] ?? .idle,
                        palette: palette
                    )
                    if index < ServiceID.allCases.count - 1 {
                        hairline(palette: palette)
                    }
                }
            }
        case .normalDashboard:
            VStack(spacing: 0) {
                ForEach(Array(ServiceID.allCases.enumerated()), id: \.element) { index, service in
                    let snapshot = viewModel.snapshots[service]
                    let monitorState = viewModel.monitorStates[service] ?? .idle
                    let tile = ServiceTileState.derive(monitor: monitorState, snapshot: snapshot)
                    rowView(for: service, tileState: tile, palette: palette)
                    if index < ServiceID.allCases.count - 1 {
                        hairline(palette: palette)
                    }
                }
            }
        }
    }

    private func rowView(
        for service: ServiceID,
        tileState: ServiceTileState,
        palette: Palette
    ) -> some View {
        ServiceRowView(
            service: service,
            tileState: tileState,
            palette: palette,
            onGrantFDA: onGrantFDA,
            onOpenCodexSetup: onOpenCodexSetup,
            onOpenMinimaxPreferences: onOpenPreferences
        )
    }

    /// Sensible per-service onboarding reason when we don't have a richer
    /// monitor state yet (e.g. cold launch).
    private func defaultReason(for service: ServiceID) -> UnconfiguredReason {
        switch service {
        case .claude: return .missingFullDiskAccess
        case .codex: return .codexNotInstalled
        case .minimax: return .minimaxTokenMissing
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(palette: Palette) -> some View {
        HStack(spacing: Tokens.Space.s12) {
            Text(footerStatus)
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkDim)
            Spacer()
            Button("Preferences") {
                onOpenPreferences()
            }
            .buttonStyle(.plain)
            .font(PopoverFont.meta())
            .foregroundColor(palette.inkDim)
            .keyboardShortcut(",", modifiers: .command)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.inkDim.opacity(0.5))
                    .frame(height: 0.5)
                    .offset(y: 1)
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(PopoverFont.meta())
            .foregroundColor(palette.inkDim)
            .keyboardShortcut("q", modifiers: .command)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.inkDim.opacity(0.5))
                    .frame(height: 0.5)
                    .offset(y: 1)
            }
        }
    }

    private var footerStatus: String {
        let latest = viewModel.snapshots.values.map(\.readAt).max()
        guard let latest else { return "No data yet" }
        let elapsed = Int(Date().timeIntervalSince(latest))
        if elapsed < 5 { return "Updated just now" }
        if elapsed < 60 { return "Updated \(elapsed)s ago" }
        let mins = elapsed / 60
        return "Updated \(mins)m ago"
    }

    // MARK: - Hairline

    private func hairline(palette: Palette) -> some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(height: Tokens.Layout.hairline)
    }
}
