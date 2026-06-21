import SwiftUI
import CuwatchCore

/// State B card — replaces the Claude row when ~/.claude/projects/ can't be
/// read because the user hasn't granted Full Disk Access.
///
/// Tap the button → opens macOS System Settings → Privacy & Security → Full
/// Disk Access via the documented `x-apple.systempreferences:` URL.
/// `cuwatch` continues polling on its normal cadence; the moment the FDA
/// permission flips on, the next ClaudeReader.read() succeeds and the card
/// auto-dismisses (the presentation switches back).
struct TCCFDACardView: View {

    let palette: Palette
    var onOpenSystemSettings: () -> Void = {}
    var onOpenReadmePrivacy: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            Text("Claude needs Full Disk Access")
                .font(PopoverFont.body(Tokens.Size.l))
                .foregroundColor(palette.ink)
            Text("cuwatch reads your local Claude Code usage from ~/.claude/projects/ — macOS requires explicit permission.")
                .font(PopoverFont.meta())
                .foregroundColor(palette.inkMute)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Space.s8) {
                Button("OPEN SYSTEM SETTINGS", action: onOpenSystemSettings)
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.brass)
                Button("WHY?", action: onOpenReadmePrivacy)
                    .buttonStyle(.plain)
                    .font(PopoverFont.label())
                    .foregroundColor(palette.inkDim)
            }
        }
        .padding(Tokens.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.surface2)
        )
    }
}
