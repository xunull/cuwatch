import SwiftUI
import CuwatchCore

/// One row in the popover body. Renders one of three shapes based on the
/// derived `ServiceTileState`:
///
/// - `.active`        — normal progress bar + ghost line + percentage + meta
/// - `.backingOff`    — same shape but dim + retry note in place of meta
/// - `.unconfigured`  — onboarding CTA (handled via `OnboardingRowView`)
/// - `.idle`          — em-dash placeholder until first publish lands
///
/// 56pt high in normal/active state, may grow when the onboarding row is shown.
struct ServiceRowView: View {

    let service: ServiceID
    let tileState: ServiceTileState
    let palette: Palette

    var onGrantFDA: () -> Void = {}
    var onOpenCodexSetup: () -> Void = {}
    var onOpenMinimaxPreferences: () -> Void = {}

    var body: some View {
        switch tileState {
        case .active(let snapshot):
            normalRow(snapshot: snapshot, dim: false, metaOverride: nil)
        case .backingOff(let stale, let reason, let nextRetryIn):
            normalRow(snapshot: stale, dim: true, metaOverride: backingOffMeta(reason: reason, nextRetryIn: nextRetryIn))
        case .unconfigured(let reason):
            OnboardingRowView(
                service: service,
                reason: reason,
                palette: palette,
                onGrantFDA: onGrantFDA,
                onOpenCodexSetup: onOpenCodexSetup,
                onOpenMinimaxPreferences: onOpenMinimaxPreferences
            )
        case .idle:
            idleRow()
        }
    }

    // MARK: - Normal-shape row (used by active and backingOff)

    private func normalRow(
        snapshot: UsageSnapshot?,
        dim: Bool,
        metaOverride: String?
    ) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s12) {
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                Text(service.displayLabel)
                    .labelStyle()
                    .foregroundColor(palette.inkMute)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.surface2)
                        .frame(height: Tokens.Layout.barHeight)
                    GeometryReader { proxy in
                        // Bar fills LEFT→RIGHT proportional to used %; bar gets
                        // longer (and more orange / red) the more you've used.
                        let frac = max(0, min(1, snapshot?.usedFraction ?? 0))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(snapshot: snapshot, dim: dim))
                            .frame(width: proxy.size.width * CGFloat(frac))
                    }
                    .frame(height: Tokens.Layout.barHeight)
                    GeometryReader { proxy in
                        let ghost = max(0, min(1, snapshot?.usedFraction ?? 0))
                        Rectangle()
                            .fill(palette.inkDim.opacity(0.7))
                            .frame(width: proxy.size.width * CGFloat(ghost), height: 1)
                            .offset(y: Tokens.Layout.barHeight / 2)
                    }
                    .frame(height: Tokens.Layout.barHeight)
                }
                .frame(height: Tokens.Layout.barHeight)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(percentText(snapshot: snapshot))
                    .font(PopoverFont.value())
                    .foregroundColor(dim ? palette.inkDim : palette.ink)
                Text(metaOverride ?? defaultMeta(snapshot: snapshot))
                    .font(PopoverFont.meta())
                    .foregroundColor(palette.inkMute)
            }
        }
        .padding(.vertical, Tokens.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func idleRow() -> some View {
        HStack(spacing: Tokens.Space.s12) {
            Text(service.displayLabel)
                .labelStyle()
                .foregroundColor(palette.inkMute)
            Spacer()
            Text("—")
                .font(PopoverFont.value())
                .foregroundColor(palette.inkDim)
        }
        .padding(.vertical, Tokens.Space.s12)
    }

    // MARK: - Helpers

    private func percentText(snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "—%" }
        let pct = Int((snapshot.usedFraction * 100).rounded())
        return "\(pct)%"
    }

    private func defaultMeta(snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "" }
        switch snapshot.window {
        case .sessionWindow5h, .weekly:
            if let resetAt = snapshot.resetAt {
                return "resets in \(short(timeUntil: resetAt, from: snapshot.readAt))"
            }
            return ""
        case .tokenBudget:
            return snapshot.usageDisplay?.combined ?? ""
        }
    }

    private func backingOffMeta(reason: MonitorFailureReason, nextRetryIn: TimeInterval) -> String {
        let label: String
        switch reason {
        case .networkError:        label = "Network error"
        case .authExpired:         label = "Auth expired"
        case .rateLimited:         label = "Rate limited"
        case .timeout:             label = "Timed out"
        case .fileSystemError:     label = "File error"
        case .parseError:          label = "Parse error"
        }
        return "\(label) · retry in \(short(seconds: nextRetryIn))"
    }

    private func barColor(snapshot: UsageSnapshot?, dim: Bool) -> SwiftUI.Color {
        if dim { return palette.inkDim }
        switch snapshot?.colorState {
        case .warn: return palette.warn
        case .danger: return palette.danger
        default: return palette.brass
        }
    }

    private func short(timeUntil target: Date, from start: Date) -> String {
        let secondsUntil = max(0, Int(target.timeIntervalSince(start)))
        let hours = secondsUntil / 3600
        let mins = (secondsUntil % 3600) / 60
        if hours == 0 {
            return "\(mins)m"
        } else {
            return "\(hours)h \(String(format: "%02d", mins))m"
        }
    }

    private func short(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            return "\(total / 60)m"
        } else {
            return "\(total / 3600)h"
        }
    }
}
