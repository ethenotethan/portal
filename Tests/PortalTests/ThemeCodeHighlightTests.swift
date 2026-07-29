import Testing
@testable import Portal

/// Each app theme pairs with a Highlightr syntax theme so highlighted code
/// follows the selected scheme instead of the old fixed `atom-one-dark`.
@Suite("Theme-paired code highlighting")
internal struct ThemeCodeHighlightTests {

    // The Highlightr themes we route to. All ship in Highlightr 2.3.0's
    // Resources/styles and are dark (every app preset is dark).
    private static let knownHighlightThemes: Set<String> = [
        "atom-one-dark",
        "tomorrow-night-eighties",
        "nord",
        "gruvbox-dark",
        "tomorrow-night",
    ]

    @Test("every preset maps to a known Highlightr dark theme")
    internal func everyPresetMapsToKnownTheme() {
        for theme in AppTheme.allCases {
            #expect(
                Self.knownHighlightThemes.contains(theme.codeHighlightTheme),
                "\(theme.id) → \(theme.codeHighlightTheme) is not a known theme"
            )
        }
    }

    @Test("midnight keeps atom-one-dark (unchanged default)")
    internal func midnightUnchanged() {
        #expect(AppTheme.midnight.codeHighlightTheme == "atom-one-dark")
    }

    @Test("distinct presets pick distinct syntax themes")
    internal func presetsAreDistinct() {
        // Cosmic/ocean/forest/rose each diverge from the midnight default so the
        // change is visible when the user switches away from Midnight.
        #expect(AppTheme.cosmic.codeHighlightTheme != AppTheme.midnight.codeHighlightTheme)
        #expect(AppTheme.ocean.codeHighlightTheme != AppTheme.midnight.codeHighlightTheme)
        #expect(AppTheme.forest.codeHighlightTheme != AppTheme.midnight.codeHighlightTheme)
        #expect(AppTheme.rose.codeHighlightTheme != AppTheme.midnight.codeHighlightTheme)
    }

    @Test("Theme.active exposes the current manager palette")
    @MainActor
    internal func themeActiveReflectsManager() {
        #expect(Theme.active.id == ThemeManager.shared.current.id)
    }
}
