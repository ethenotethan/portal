import SwiftUI

// Dynamic theme system: the active palette is swapped at runtime via
// `ThemeManager.shared`, and `Theme` properties delegate to it so existing
// call sites pick up the change without API churn.

// MARK: - Theme Presets

/// A complete color palette. New presets are cheap to add — just define
/// the hex values and append to `AppTheme.allCases`.
internal struct AppTheme: Identifiable, Codable, Sendable {
    internal let id: String
    internal let displayName: String
    internal let description: String
    internal let swatches: [String]  // preview hexes: [background, surface, accent, primary]

    internal static let allCases: [AppTheme] = [.midnight, .cosmic, .ocean, .forest, .rose]

    // Raw hex strings — decoded lazily by ThemeManager into Color values.
    internal let backgroundHex: String
    internal let surfaceHex: String
    internal let surfaceHoverHex: String
    internal let primaryHex: String
    internal let secondaryHex: String
    internal let tertiaryHex: String
    internal let accentHex: String
    internal let successHex: String
    internal let warningHex: String
    internal let agentAccentHex: String
    internal let borderHex: String

    // Thought-graph ramp (shared across all themes for now — these are
    // semantic tool colors, not decor).
    internal let graphSearchHex: String
    internal let graphReadHex: String
    internal let graphWriteHex: String
    internal let graphPatchHex: String
    internal let graphTerminalHex: String
    internal let graphReasoningHex: String
    internal let graphOtherHex: String

    // MARK: Presets

    internal static let midnight = AppTheme(
        id: "midnight",
        displayName: "Midnight",
        description: "Near-black with soft purple-blue",
        swatches: ["1a1a1a", "2a2a2a", "7c7cff", "f0f0f0"],
        backgroundHex: "1a1a1a",
        surfaceHex: "2a2a2a",
        surfaceHoverHex: "333333",
        primaryHex: "f0f0f0",
        secondaryHex: "9a9a9a",
        tertiaryHex: "666666",
        accentHex: "7c7cff",
        successHex: "5cb85c",
        warningHex: "e8a838",
        agentAccentHex: "ff6ac1",
        borderHex: "3a3a3a",
        graphSearchHex: "e8a838",
        graphReadHex: "5aa9e6",
        graphWriteHex: "5cb87a",
        graphPatchHex: "e07a5f",
        graphTerminalHex: "9d7cff",
        graphReasoningHex: "8a8f98",
        graphOtherHex: "7d8597"
    )

    internal static let cosmic = AppTheme(
        id: "cosmic",
        displayName: "Cosmic",
        description: "Deep indigo with warm amber",
        swatches: ["14121f", "221e33", "e8a838", "ecebf5"],
        backgroundHex: "14121f",
        surfaceHex: "221e33",
        surfaceHoverHex: "2c2840",
        primaryHex: "ecebf5",
        secondaryHex: "9b95b8",
        tertiaryHex: "615a7d",
        accentHex: "e8a838",
        successHex: "4ecdc4",
        warningHex: "ff8c42",
        agentAccentHex: "c77dff",
        borderHex: "36304d",
        graphSearchHex: "e8a838",
        graphReadHex: "5aa9e6",
        graphWriteHex: "5cb87a",
        graphPatchHex: "e07a5f",
        graphTerminalHex: "9d7cff",
        graphReasoningHex: "8a8f98",
        graphOtherHex: "7d8597"
    )

    internal static let ocean = AppTheme(
        id: "ocean",
        displayName: "Ocean",
        description: "Abyssal blue with teal glow",
        swatches: ["0d1929", "13263a", "3ddc97", "e0f0ff"],
        backgroundHex: "0d1929",
        surfaceHex: "13263a",
        surfaceHoverHex: "1a3048",
        primaryHex: "e0f0ff",
        secondaryHex: "7a9ab5",
        tertiaryHex: "4a6580",
        accentHex: "3ddc97",
        successHex: "3ddc97",
        warningHex: "f4a261",
        agentAccentHex: "48cae4",
        borderHex: "1e3a52",
        graphSearchHex: "e8a838",
        graphReadHex: "5aa9e6",
        graphWriteHex: "5cb87a",
        graphPatchHex: "e07a5f",
        graphTerminalHex: "9d7cff",
        graphReasoningHex: "8a8f98",
        graphOtherHex: "7d8597"
    )

    internal static let forest = AppTheme(
        id: "forest",
        displayName: "Forest",
        description: "Deep woodland greens",
        swatches: ["111a12", "1a2b1c", "8bc34a", "e8f5e9"],
        backgroundHex: "111a12",
        surfaceHex: "1a2b1c",
        surfaceHoverHex: "243526",
        primaryHex: "e8f5e9",
        secondaryHex: "8aaa8c",
        tertiaryHex: "5a7a5c",
        accentHex: "8bc34a",
        successHex: "66bb6a",
        warningHex: "ff9800",
        agentAccentHex: "ffab40",
        borderHex: "2a3b2c",
        graphSearchHex: "e8a838",
        graphReadHex: "5aa9e6",
        graphWriteHex: "5cb87a",
        graphPatchHex: "e07a5f",
        graphTerminalHex: "9d7cff",
        graphReasoningHex: "8a8f98",
        graphOtherHex: "7d8597"
    )

    internal static let rose = AppTheme(
        id: "rose",
        displayName: "Rose",
        description: "Warm charcoal with rose accents",
        swatches: ["1c1215", "2e1e22", "ff6b9d", "fce8ef"],
        backgroundHex: "1c1215",
        surfaceHex: "2e1e22",
        surfaceHoverHex: "3a262b",
        primaryHex: "fce8ef",
        secondaryHex: "b08a91",
        tertiaryHex: "7a5560",
        accentHex: "ff6b9d",
        successHex: "81c784",
        warningHex: "ffb74d",
        agentAccentHex: "ce93d8",
        borderHex: "3e2a2f",
        graphSearchHex: "e8a838",
        graphReadHex: "5aa9e6",
        graphWriteHex: "5cb87a",
        graphPatchHex: "e07a5f",
        graphTerminalHex: "9d7cff",
        graphReasoningHex: "8a8f98",
        graphOtherHex: "7d8597"
    )

    // Dimensions are shared — not theme-dependent.
    internal static let bubbleRadius: CGFloat = 16
    internal static let bubblePaddingH: CGFloat = 20
    internal static let bubblePaddingV: CGFloat = 14
    internal static let pillRadius: CGFloat = 12
    internal static let pillSpacing: CGFloat = 10
    internal static let avatarSize: CGFloat = 48
    internal static let illustrationHeight: CGFloat = 260
}

// MARK: - Theme Manager

/// Singleton holding the active palette. Observers re-render on change.
/// Persisted to UserDefaults so the choice survives relaunch.
internal final class ThemeManager: ObservableObject {
    // swiftlint:disable:next no_new_singletons
    nonisolated(unsafe) internal static let shared = ThemeManager()

    private static let storageKey = "portal.activeTheme"

    @Published internal var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: Self.storageKey)
            rebuildColors()
        }
    }

    // Cached Color values for the current theme — avoids re-parsing hex on
    // every `Theme.background` access.
    internal private(set) var colors: ThemeColors

    private init() {
        let savedID = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppTheme.midnight.id
        let selected = AppTheme.allCases.first { $0.id == savedID } ?? .midnight
        self.current = selected
        self.colors = ThemeColors(theme: selected)
    }

    internal func select(_ theme: AppTheme) {
        current = theme
    }

    private func rebuildColors() {
        colors = ThemeColors(theme: current)
    }
}

/// Pre-decoded Color set for one palette. Properties here are the single
/// source of truth that `Theme.xxx` delegates to.
internal struct ThemeColors: Sendable {
    internal let background: Color
    internal let surface: Color
    internal let surfaceHover: Color
    internal let primary: Color
    internal let secondary: Color
    internal let tertiary: Color
    internal let accent: Color
    internal let success: Color
    internal let warning: Color
    internal let agentAccent: Color
    internal let border: Color
    internal let graphSearch: Color
    internal let graphRead: Color
    internal let graphWrite: Color
    internal let graphPatch: Color
    internal let graphTerminal: Color
    internal let graphReasoning: Color
    internal let graphOther: Color
    internal let graphCompaction: Color

    internal init(theme: AppTheme) {
        background = Color(hex: theme.backgroundHex) ?? .black
        surface = Color(hex: theme.surfaceHex) ?? .gray
        surfaceHover = Color(hex: theme.surfaceHoverHex) ?? .gray
        primary = Color(hex: theme.primaryHex) ?? .white
        secondary = Color(hex: theme.secondaryHex) ?? .gray
        tertiary = Color(hex: theme.tertiaryHex) ?? .gray
        accent = Color(hex: theme.accentHex) ?? .purple
        success = Color(hex: theme.successHex) ?? .green
        warning = Color(hex: theme.warningHex) ?? .orange
        agentAccent = Color(hex: theme.agentAccentHex) ?? .pink
        border = Color(hex: theme.borderHex) ?? .gray
        graphSearch = Color(hex: theme.graphSearchHex) ?? .orange
        graphRead = Color(hex: theme.graphReadHex) ?? .blue
        graphWrite = Color(hex: theme.graphWriteHex) ?? .green
        graphPatch = Color(hex: theme.graphPatchHex) ?? .red
        graphTerminal = Color(hex: theme.graphTerminalHex) ?? .purple
        graphReasoning = Color(hex: theme.graphReasoningHex) ?? .gray
        graphOther = Color(hex: theme.graphOtherHex) ?? .gray
        // Compaction parchment — desaturated tan, constant across themes.
        graphCompaction = Color(red: 0.804, green: 0.722, blue: 0.569)
    }
}

// MARK: - Theme (backward-compatible static facade)

/// Static facade preserved for the ~1560 existing `Theme.xxx` call sites.
/// Each property delegates to `ThemeManager.shared.colors`.
internal enum Theme {
    private static var colors: ThemeColors { ThemeManager.shared.colors }

    // MARK: Backgrounds
    internal static var background: Color { colors.background }
    internal static var surface: Color { colors.surface }
    internal static var surfaceHover: Color { colors.surfaceHover }

    // MARK: Text
    internal static var primary: Color { colors.primary }
    internal static var secondary: Color { colors.secondary }
    internal static var tertiary: Color { colors.tertiary }

    // MARK: Accents
    internal static var accent: Color { colors.accent }
    internal static var success: Color { colors.success }
    internal static var warning: Color { colors.warning }
    internal static var agentAccent: Color { colors.agentAccent }

    // MARK: Thought Graph Ramp
    internal static var graphSearch: Color { colors.graphSearch }
    internal static var graphRead: Color { colors.graphRead }
    internal static var graphWrite: Color { colors.graphWrite }
    internal static var graphPatch: Color { colors.graphPatch }
    internal static var graphTerminal: Color { colors.graphTerminal }
    internal static var graphReasoning: Color { colors.graphReasoning }
    internal static var graphOther: Color { colors.graphOther }
    internal static var graphCompaction: Color { colors.graphCompaction }

    // MARK: Borders
    internal static var border: Color { colors.border }

    // MARK: Dimensions (constants, not theme-dependent)
    internal static var bubbleRadius: CGFloat { AppTheme.bubbleRadius }
    internal static var bubblePaddingH: CGFloat { AppTheme.bubblePaddingH }
    internal static var bubblePaddingV: CGFloat { AppTheme.bubblePaddingV }
    internal static var pillRadius: CGFloat { AppTheme.pillRadius }
    internal static var pillSpacing: CGFloat { AppTheme.pillSpacing }
    internal static var avatarSize: CGFloat { AppTheme.avatarSize }
    internal static var illustrationHeight: CGFloat { AppTheme.illustrationHeight }
}
