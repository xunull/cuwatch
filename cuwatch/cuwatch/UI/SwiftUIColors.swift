import SwiftUI
import CuwatchCore

/// SwiftUI bridge to the design tokens.
///
/// SwiftUI's `Color` doesn't share constructors with `NSColor`, so we map our
/// `HexColor` through. Light/dark mode switching is handled at the view level
/// by reading `@Environment(\.colorScheme)`.
extension HexColor {
    /// Convert to a SwiftUI Color. Resolves the same RGB values regardless of
    /// color scheme — call sites pick between dark/light token sets explicitly.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
