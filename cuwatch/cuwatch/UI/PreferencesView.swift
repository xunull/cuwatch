import SwiftUI
import CuwatchCore

/// Preferences panel — slides in from the right when the user hits the footer
/// link in `PopoverView`. 340pt wide, same dark surface, three sections.
///
/// State A-F per the plan; this view implements State F (Preferences). The
/// "‹ BACK" navigation invokes `onBack` so the container view can swap back
/// to the dashboard.
struct PreferencesView: View {

    @ObservedObject var viewModel: PreferencesViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.palette) private var palette
    let onBack: () -> Void

    // MARK: - Inline form state

    @State private var minimaxTokenInput: String = ""
    @State private var minimaxTokenSheetOpen: Bool = false
    @State private var minimaxTokenError: String? = nil
    @State private var clearHistoryConfirmOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Tokens.Space.s16)
                .overlay(alignment: .bottom) { hairline }

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s24) {
                    servicesSection
                    behaviorSection
                    dataPrivacySection
                }
                .padding(.top, Tokens.Space.s24)
            }
        }
        .padding(Tokens.Space.s24)
        .frame(width: Tokens.Layout.popoverWidth, alignment: .topLeading)
        .background(palette.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Text("‹ BACK")
                    .labelStyle()
                    .foregroundColor(palette.inkMute)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w", modifiers: .command)

            Spacer()
            Text("PREFERENCES")
                .labelStyle()
                .foregroundColor(palette.brass)
            Spacer()
            // Empty mirror of back-button width so PREFERENCES sits centered.
            Color.clear.frame(width: 36, height: 1)
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            sectionHeader("Services")
            // CLAUDE — filesystem only, no token.
            servicePresenceRow(
                service: .claude,
                detail: "Reads ~/.claude/projects/. No token required."
            )
            // CODEX — filesystem only, no token.
            servicePresenceRow(
                service: .codex,
                detail: "Reads ~/.codex/sessions/. Install codex CLI to enable."
            )
            // MINIMAX — bearer token.
            minimaxTokenRow
            minimaxEndpointRow
        }
    }

    private func servicePresenceRow(service: ServiceID, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack {
                Text(service.displayLabel)
                    .labelStyle()
                    .foregroundColor(palette.brass)
                Spacer()
                Text("Filesystem")
                    .labelStyle()
                    .foregroundColor(palette.inkDim)
            }
            Text(detail)
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkMute)
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    private var minimaxTokenRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack {
                Text("MINIMAX")
                    .labelStyle()
                    .foregroundColor(palette.brass)
                Spacer()
                if viewModel.minimaxTokenConfigured {
                    Text(viewModel.minimaxTokenMasked)
                        .font(PopoverFont.value())
                        .foregroundColor(palette.ink)
                    Button("REPLACE") {
                        minimaxTokenInput = ""
                        minimaxTokenError = nil
                        minimaxTokenSheetOpen = true
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.brass)
                    Button("REMOVE") {
                        viewModel.removeMinimaxToken()
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.danger)
                } else {
                    Button("ADD TOKEN") {
                        minimaxTokenInput = ""
                        minimaxTokenError = nil
                        minimaxTokenSheetOpen = true
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.brass)
                }
            }
            if minimaxTokenSheetOpen {
                minimaxTokenInputForm
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    private var minimaxTokenInputForm: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text("Paste your Minimax Bearer token (starts with mxp_...)")
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkMute)
            // Note: SecureField + monospaced font on macOS 12 has known quirks,
            // so we use a plain TextField. The token is masked in the row
            // itself once saved, and the field clears as soon as the panel
            // re-opens.
            TextField("mxp_…", text: $minimaxTokenInput)
                .textFieldStyle(.plain)
                .font(PopoverFont.value())
                .padding(Tokens.Space.s8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(palette.brass, lineWidth: 1)
                )
                .foregroundColor(palette.ink)
            if let err = minimaxTokenError {
                Text(err)
                    .font(PopoverFont.meta())
                    .foregroundColor(palette.danger)
            }
            HStack {
                Button("SAVE") {
                    do {
                        try viewModel.saveMinimaxToken(minimaxTokenInput)
                        minimaxTokenSheetOpen = false
                        minimaxTokenInput = ""
                        minimaxTokenError = nil
                    } catch PreferencesViewModel.TokenSaveError.empty {
                        minimaxTokenError = "Token is empty"
                    } catch {
                        minimaxTokenError = "Save failed: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.plain)
                .font(PopoverFont.label())
                .foregroundColor(palette.brass)
                Button("CANCEL") {
                    minimaxTokenSheetOpen = false
                    minimaxTokenInput = ""
                    minimaxTokenError = nil
                }
                .buttonStyle(.plain)
                .font(PopoverFont.label())
                .foregroundColor(palette.inkDim)
                Spacer()
            }
        }
        .padding(.top, Tokens.Space.s4)
    }

    private var minimaxEndpointRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack {
                Text("ENDPOINT")
                    .labelStyle()
                    .foregroundColor(palette.inkMute)
                Spacer()
                ForEach(MinimaxEndpoint.allCases, id: \.self) { option in
                    Button(option.displayName) {
                        viewModel.setMinimaxEndpoint(option)
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.value())
                    .foregroundColor(
                        viewModel.store.minimaxEndpoint == option ? palette.brass : palette.inkDim
                    )
                }
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            sectionHeader("Behavior")
            pollIntervalRow
            mainServiceLockRow
        }
    }

    private var pollIntervalRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack {
                Text("POLL EVERY")
                    .labelStyle()
                    .foregroundColor(palette.inkMute)
                Spacer()
                ForEach([10.0, 15.0, 30.0, 60.0, 300.0], id: \.self) { secs in
                    Button(formatInterval(secs)) {
                        viewModel.setPollInterval(secs)
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.value())
                    .foregroundColor(
                        viewModel.store.pollIntervalSeconds == secs ? palette.brass : palette.inkDim
                    )
                }
            }
            if viewModel.store.isPollIntervalAtHighFrequencyWarningThreshold {
                Text("Frequent polls may impact battery life.")
                    .font(PopoverFont.meta())
                    .foregroundColor(palette.warn)
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    private var mainServiceLockRow: some View {
        HStack {
            Text("MAIN SERVICE")
                .labelStyle()
                .foregroundColor(palette.inkMute)
            Spacer()
            ForEach(MainServiceLock.allCases, id: \.self) { option in
                Button(shortLabel(option)) {
                    viewModel.setMainServiceLock(option)
                }
                .buttonStyle(.plain)
                .font(PopoverFont.value())
                .foregroundColor(
                    viewModel.store.mainServiceLock == option ? palette.brass : palette.inkDim
                )
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    // MARK: - Data & Privacy

    private var dataPrivacySection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s16) {
            sectionHeader("Data & Privacy")
            historyRetentionRow
            clearHistoryRow
            revealRow
        }
    }

    private var historyRetentionRow: some View {
        HStack {
            Text("RETAIN HISTORY")
                .labelStyle()
                .foregroundColor(palette.inkMute)
            Spacer()
            ForEach(PreferencesStore.historyRetentionOptions, id: \.self) { days in
                Button(retentionLabel(days)) {
                    viewModel.setHistoryRetentionDays(days)
                }
                .buttonStyle(.plain)
                .font(PopoverFont.value())
                .foregroundColor(
                    viewModel.store.historyRetentionDays == days ? palette.brass : palette.inkDim
                )
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    private var clearHistoryRow: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            if clearHistoryConfirmOpen {
                HStack {
                    Text("Delete cuwatch history?")
                        .font(PopoverFont.meta())
                        .foregroundColor(palette.ink)
                    Spacer()
                    Button("CANCEL") { clearHistoryConfirmOpen = false }
                        .buttonStyle(.plain)
                        .font(PopoverFont.label())
                        .foregroundColor(palette.inkDim)
                    Button("DELETE") {
                        _ = try? viewModel.clearHistory()
                        clearHistoryConfirmOpen = false
                    }
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.danger)
                }
            } else {
                Button("CLEAR HISTORY") { clearHistoryConfirmOpen = true }
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.danger)
            }
        }
        .padding(.vertical, Tokens.Space.s4)
    }

    private var revealRow: some View {
        Button("OPEN APPLICATION SUPPORT") {
            if let url = viewModel.applicationSupportURL() {
                #if canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
            }
        }
        .buttonStyle(.plain)
        .font(PopoverFont.label())
        .foregroundColor(palette.inkDim)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(text)
                .labelStyle()
                .foregroundColor(palette.brass)
            hairline
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(height: Tokens.Layout.hairline)
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            return "\(Int(seconds / 60))m"
        }
        return "\(Int(seconds))s"
    }

    private func retentionLabel(_ days: Int) -> String {
        days < 0 ? "Forever" : "\(days)d"
    }

    private func shortLabel(_ lock: MainServiceLock) -> String {
        switch lock {
        case .auto: return "Auto"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .minimax: return "Minimax"
        }
    }
}
