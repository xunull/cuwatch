import SwiftUI
import CuwatchCore

/// Active palette for the popover. SwiftUI views read this via `@Environment`
/// so a single light/dark toggle flips every color at once without each view
/// remembering its own conditional.
struct Palette: Equatable {
    let background: SwiftUI.Color
    let surface: SwiftUI.Color
    let surface2: SwiftUI.Color
    let ink: SwiftUI.Color
    let inkMute: SwiftUI.Color
    let inkDim: SwiftUI.Color
    let brass: SwiftUI.Color
    let warn: SwiftUI.Color
    let danger: SwiftUI.Color
    let hairline: SwiftUI.Color

    static let dark = Palette(
        background: Tokens.DarkColor.bg.swiftUIColor,
        surface: Tokens.DarkColor.surface.swiftUIColor,
        surface2: Tokens.DarkColor.surface2.swiftUIColor,
        ink: Tokens.DarkColor.ink.swiftUIColor,
        inkMute: Tokens.DarkColor.inkMute.swiftUIColor,
        inkDim: Tokens.DarkColor.inkDim.swiftUIColor,
        brass: Tokens.DarkColor.brass.swiftUIColor,
        warn: Tokens.DarkColor.warn.swiftUIColor,
        danger: Tokens.DarkColor.danger.swiftUIColor,
        hairline: Tokens.DarkColor.surface2.swiftUIColor
    )

    static let light = Palette(
        background: Tokens.LightColor.bg.swiftUIColor,
        surface: Tokens.LightColor.surface.swiftUIColor,
        surface2: Tokens.LightColor.surface2.swiftUIColor,
        ink: Tokens.LightColor.ink.swiftUIColor,
        inkMute: Tokens.LightColor.inkMute.swiftUIColor,
        inkDim: Tokens.LightColor.inkDim.swiftUIColor,
        brass: Tokens.LightColor.brass.swiftUIColor,
        warn: Tokens.LightColor.warn.swiftUIColor,
        danger: Tokens.LightColor.danger.swiftUIColor,
        // 1px hairline on parchment uses a warmer mid-tone than the dark variant.
        hairline: HexColor(0xC9BFAA).swiftUIColor
    )

    static func resolve(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

private struct PaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue: Palette = .dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteEnvironmentKey.self] }
        set { self[PaletteEnvironmentKey.self] = newValue }
    }
}
