import SwiftUI
import CuwatchCore

/// Wraps any SwiftUI view with a live `.environment(\.locale, ...)` that
/// re-renders whenever `PreferencesStore.languagePreference` changes.
///
/// Why a wrapper view (instead of injecting locale at the AppDelegate level)?
/// `NSHostingController` takes a single root view at construction time and
/// doesn't react to AppDelegate-level state. To get **live** language
/// switching (no app restart), we need an ObservableObject inside the SwiftUI
/// tree that owns the locale and re-applies it via `.environment(\.locale,)`.
///
/// Added 2026-06-26 i18n. See `docs/i18n-zh-hans-design.md`.
struct LocaleBridge<Content: View>: View {

    @ObservedObject var preferencesStore: PreferencesStore
    let content: Content

    var body: some View {
        content
            .environment(\.locale, preferencesStore.effectiveLocale)
            // Force re-render on locale change. Without `.id(...)`, some
            // SwiftUI subviews cache their rendered text and skip the
            // re-evaluation when `\.locale` updates.
            .id(preferencesStore.languagePreference)
    }
}
