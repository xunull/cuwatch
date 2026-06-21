import SwiftUI
import CuwatchCore

/// Type-style helpers using the system monospaced design font.
///
/// Per /plan-design-review 2026-06-21 reversal: dropped IBM Plex Mono bundle
/// in favor of SwiftUI's `.system(..., design: .monospaced)` which resolves
/// to SF Mono on macOS 13+ (Menlo on older). Tradeoff: less wedge differentiation,
/// no font bundle to ship, native rendering, no licensing attribution overhead.
/// See DESIGN.md Decisions Log entry of the same date.
enum PopoverFont {

    static func display(_ size: CGFloat = Tokens.Size.display) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
            .monospacedDigit()
    }

    static func body(_ size: CGFloat = Tokens.Size.l) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
            .monospacedDigit()
    }

    static func value(_ size: CGFloat = Tokens.Size.m) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
            .monospacedDigit()
    }

    static func meta(_ size: CGFloat = Tokens.Size.s) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
            .monospacedDigit()
    }

    /// Uppercase tracked labels ("CLAUDE", "5H WINDOW", etc).
    static func label(_ size: CGFloat = Tokens.Size.xs) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
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
