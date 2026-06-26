import SwiftUI
import CuwatchCore

/// Logbook slide-in panel — surfaces aggregated Codex stats from
/// `~/.codex/state_5.sqlite`. Mirrors the slide-in pattern of
/// `PreferencesView` (same 340pt width, same back/title header, same
/// hairline + meta footer).
///
/// Design: see DESIGN.md §"Logbook slide-in panel" (added 2026-06-26).
/// Doc: `docs/codex-logbook-design.md`.
///
/// v0.1 surfaces Codex only. Claude / Minimax logbook reserved for v1.1+.
struct LogbookView: View {

    /// Synchronous read of the logbook from the configured reader.
    /// Called on `.onAppear` and on manual refresh.
    let loadLogbook: () -> CodexLogbook?

    let onBack: () -> Void

    @State private var book: CodexLogbook?
    @State private var hasLoaded = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, Tokens.Space.s16)
                .overlay(alignment: .bottom) { hairline }

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s24) {
                    if let book = book {
                        statsBody(book: book)
                    } else if hasLoaded {
                        emptyState
                    } else {
                        // Brief render before .onAppear fires.
                        Color.clear.frame(height: 1)
                    }
                }
                .padding(.top, Tokens.Space.s24)
            }

            Spacer(minLength: 0)

            footer
                .padding(.top, Tokens.Space.s16)
                .overlay(alignment: .top) { hairline }
        }
        .padding(Tokens.Space.s24)
        .frame(width: Tokens.Layout.popoverWidth, alignment: .topLeading)
        .background(palette.surface)
        .onAppear {
            book = loadLogbook()
            hasLoaded = true
        }
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
            Text("CODEX · LOGBOOK")
                .labelStyle()
                .foregroundColor(palette.brass)
            Spacer()
            // Mirror back-button width so the title sits centered.
            Color.clear.frame(width: 36, height: 1)
        }
    }

    // MARK: - Stats body

    @ViewBuilder
    private func statsBody(book: CodexLogbook) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s24) {
            statRow(
                label: "Cumulative tokens",
                value: Self.formatLargeTokens(book.cumulativeTokens),
                size: .display
            )
            statRow(
                label: "Peak tokens · single thread",
                value: Self.formatLargeTokens(book.peakTokensSingleThread),
                size: .xl
            )
            statRow(
                label: "Active days",
                value: "\(book.activeDays) / \(book.totalCalendarDays)",
                size: .xl,
                caption: book.firstActiveDate.map { "Since \(Self.formatDate($0))" }
            )
            statRow(
                label: "Longest streak · current streak",
                value: "\(book.longestStreakDays) d  ·  \(book.currentStreakDays) d",
                size: .xl
            )
        }
    }

    private enum ValueSize {
        case display, xl
    }

    @ViewBuilder
    private func statRow(label: String, value: String, size: ValueSize, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(label)
                .labelStyle()
                .foregroundColor(palette.inkDim)
            Text(value)
                .font(size == .display ? PopoverFont.display() : PopoverFont.display(Tokens.Size.xl))
                .foregroundColor(palette.ink)
            if let caption = caption {
                Text(caption)
                    .font(PopoverFont.meta())
                    .foregroundColor(palette.inkDim)
            }
        }
    }

    // MARK: - Empty / footer

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            Text("No Codex activity on this Mac yet")
                .font(PopoverFont.body())
                .foregroundColor(palette.inkMute)
            Text("Run `codex` or open Codex.app to start filling the logbook.")
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkDim)
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text("This Mac · this account · CLI + Codex.app")
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkMute)
            Text("Codex.app shows cross-device aggregates that won't match.")
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkDim)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(height: Tokens.Layout.hairline)
    }

    // MARK: - Formatting

    /// Format a token count as "5.05B" / "312M" / "78K" / "1,234".
    /// Plain English units — cuwatch UI is English-only per
    /// /plan-design-review D5.
    static func formatLargeTokens(_ n: Int64) -> String {
        let absN = abs(n)
        if absN >= 1_000_000_000 {
            return String(format: "%.2fB", Double(n) / 1_000_000_000.0)
        }
        if absN >= 1_000_000 {
            return String(format: "%.0fM", Double(n) / 1_000_000.0)
        }
        if absN >= 1_000 {
            return String(format: "%.0fK", Double(n) / 1_000.0)
        }
        return String(n)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
