import SwiftUI
import CuwatchCore

/// Type-style helpers using the bundled Sarasa Mono SC font.
///
/// Per 2026-06-26 i18n reversal: bundled Sarasa Mono SC (SIL OFL 1.1) replaces
/// the 2026-06-21 SF Mono choice. Sarasa Mono SC is a true 1:2 CJK + Latin
/// monospace font — the only way to keep "Everything: monospaced" wedge intact
/// once we ship Chinese labels. Iosevka-derived Latin DNA is a closer fit for
/// the "1960s workshop instrument" anchor than SF Mono's neutral system look.
///
/// PostScript names (verified by inspecting the `name` table of each TTF):
/// - `Sarasa-Mono-SC-Regular` (weight 400)
/// - `Sarasa-Mono-SC-SemiBold` (weight 600 — replaces the previous "Medium 500"
///   role; Sarasa Mono SC doesn't ship a 500 weight)
///
/// The fonts are loaded automatically via `INFOPLIST_KEY_ATSApplicationFontsPath = "Fonts"`
/// in the cuwatch app target — no runtime `CTFontManagerRegisterFontsForURLs`
/// needed. See DESIGN.md Decisions Log entry 2026-06-26.
enum PopoverFont {

    /// Regular weight font name. Used for body, display, meta, value (non-bold).
    static let regularName: String = "Sarasa-Mono-SC-Regular"
    /// Heavier weight font name. Used for uppercase tracked labels and value-emphasis.
    static let emphasisName: String = "Sarasa-Mono-SC-SemiBold"

    static func display(_ size: CGFloat = Tokens.Size.display) -> Font {
        Font.custom(regularName, size: size).monospacedDigit()
    }

    static func body(_ size: CGFloat = Tokens.Size.l) -> Font {
        Font.custom(regularName, size: size).monospacedDigit()
    }

    static func value(_ size: CGFloat = Tokens.Size.m) -> Font {
        Font.custom(emphasisName, size: size).monospacedDigit()
    }

    static func meta(_ size: CGFloat = Tokens.Size.s) -> Font {
        Font.custom(regularName, size: size).monospacedDigit()
    }

    /// Uppercase tracked labels ("CLAUDE", "5H WINDOW", etc).
    static func label(_ size: CGFloat = Tokens.Size.xs) -> Font {
        Font.custom(emphasisName, size: size)
    }
}

extension View {
    /// Apply the uppercase label style — used for service names + labels.
    /// TODO: 0.14em tracking (per DESIGN.md) requires `View.tracking()` which is
    /// macOS 13+. Either bump deployment target or migrate to AttributedString.
    func labelStyle() -> some View {
        self
            .font(PopoverFont.label())
            .textCase(.uppercase)
    }
}
