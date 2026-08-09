import Foundation

// The app's typeface, as a fourth appearance axis alongside the palette, the
// button treatment, and the toolbar icons. Expressed as cases rather than as a
// `Font.Design` so this stays out of SwiftUI — the view layer maps a case onto a
// design and a width.

/// The typeface used for text throughout the app.
///
/// Monospaced surfaces — code blocks, IDs, timestamps, transport logs — opt out
/// of this and stay monospaced whatever is selected here. Those places are
/// monospaced because the content needs aligned columns, not because of taste,
/// and serif JSON is unreadable.
internal enum AppFontTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case rounded
    case serif
    case condensed
    case monospaced

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .condensed: return "Condensed"
        case .monospaced: return "Monospaced"
        }
    }

    internal var detail: String {
        switch self {
        case .system: return "San Francisco, as shipped"
        case .rounded: return "Softer, friendlier letterforms"
        case .serif: return "Bookish, with serifs"
        case .condensed: return "Narrower — more words per line"
        case .monospaced: return "Fixed width everywhere"
        }
    }

    /// Sample text for the settings preview. Deliberately mixed-case with
    /// digits: the difference between these is easiest to see in the shapes of
    /// `a`, `g`, and `1`.
    internal var sample: String { "Portal 123" }

    /// `false` for `system`, which is a hand-off: no root modifier is applied at
    /// all, so an existing user's type is untouched down to the last hairline.
    internal var isCustom: Bool { self != .system }

    /// The shipped typeface. Changing every glyph in the app is not something to
    /// do to someone who never asked.
    internal static let `default`: AppFontTheme = .system

    internal init(storedValue: String?) {
        self = storedValue.flatMap(AppFontTheme.init(rawValue:)) ?? .default
    }
}
