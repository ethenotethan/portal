import Testing
import Foundation
@testable import Portal

/// The typeface setting changes every glyph in the app from one root modifier,
/// so its default and its fallback are the whole safety margin: a wrong default
/// restyles the app for someone who never opened Settings, and a value from a
/// newer build that decodes to garbage would do the same.
@Suite("App font themes")
internal struct AppFontThemeTests {

    @Test("the shipped default is the typeface the app already had")
    internal func defaultIsTheStatusQuo() {
        #expect(AppFontTheme.default == .system)
        #expect(AppFontTheme(storedValue: nil) == .system)
    }

    @Test("system is a hand-off, not a treatment")
    internal func systemAppliesNoModifier() {
        // `portalAppFont()` branches on `isCustom` to apply no modifier at all
        // for `system`. That is what guarantees an untouched app rather than one
        // re-rendered through a modifier that happens to resolve to the same
        // design.
        #expect(!AppFontTheme.system.isCustom)
        for theme in AppFontTheme.allCases where theme != .system {
            #expect(theme.isCustom, "\(theme.rawValue) would apply no font modifier")
        }
    }

    @Test("an unknown stored value falls back to the default")
    internal func unknownValuesDowngrade() {
        // Written by a newer build, or hand-edited into the defaults plist.
        #expect(AppFontTheme(storedValue: "blackletter") == .system)
        #expect(AppFontTheme(storedValue: "") == .system)
        #expect(AppFontTheme(storedValue: "System") == .system)
    }

    @Test("every theme round-trips through its raw value")
    internal func rawValuesRoundTrip() {
        for theme in AppFontTheme.allCases {
            #expect(AppFontTheme(storedValue: theme.rawValue) == theme)
            #expect(theme.id == theme.rawValue)
        }
        #expect(Set(AppFontTheme.allCases.map(\.rawValue)).count == AppFontTheme.allCases.count)
    }

    @Test("every theme is labelled and described distinctly")
    internal func labelsAndDetailsAreDistinct() {
        let themes = AppFontTheme.allCases
        // Two cards reading the same thing is indistinguishable from a broken
        // setting, since the visible difference between some of these is subtle.
        #expect(Set(themes.map(\.label)).count == themes.count)
        #expect(Set(themes.map(\.detail)).count == themes.count)
        for theme in themes {
            #expect(!theme.label.isEmpty)
            #expect(!theme.detail.isEmpty)
            #expect(!theme.sample.isEmpty)
        }
    }

    @Test("the sample text shows the letterforms that differ")
    internal func sampleExercisesTheTelltaleGlyphs() {
        // The previews are small, and Serif vs System vs Rounded is easiest to
        // read off a lowercase bowl and a digit. A sample of only capitals
        // would make several cards look identical.
        let sample = AppFontTheme.system.sample
        #expect(sample.contains { $0.isLowercase })
        #expect(sample.contains { $0.isNumber })
    }

    @Test("codable round-trips through storage")
    internal func codableRoundTrip() throws {
        for theme in AppFontTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            #expect(try JSONDecoder().decode(AppFontTheme.self, from: data) == theme)
        }
    }
}
