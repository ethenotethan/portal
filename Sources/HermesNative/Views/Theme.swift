import SwiftUI

/// Dark-mode color palette for the HermesNative chat interface.
/// Matches the design spec: near-black background, dark gray cards, off-white text.
/// Note: Color.init?(hex:) is defined in Persona.swift (failable).
/// We use force-unwrap here since all hex values are hardcoded and valid.
enum Theme {
    // MARK: - Backgrounds
    static let background = Color(hex: "1a1a1a")!
    static let surface = Color(hex: "2a2a2a")!       // cards, bubbles
    static let surfaceHover = Color(hex: "333333")!

    // MARK: - Text
    static let primary = Color(hex: "f0f0f0")!       // off-white
    static let secondary = Color(hex: "9a9a9a")!     // muted gray
    static let tertiary = Color(hex: "666666")!       // dimmed

    // MARK: - Accents
    static let accent = Color(hex: "7c7cff")!         // soft purple-blue
    static let success = Color(hex: "5cb85c")!        // green for ✓
    static let warning = Color(hex: "e8a838")!        // amber
    static let agentAccent = Color(hex: "ff6ac1")!    // hot pink — subagent nodes

    // MARK: - Thought Graph Ramp
    // One family: mid-saturation jewel tones that sit together on the dark
    // canvas instead of mixing Theme colors with raw SwiftUI system colors.
    static let graphSearch = Color(hex: "e8a838")!    // amber — looking
    static let graphRead = Color(hex: "5aa9e6")!      // sky — taking in
    static let graphWrite = Color(hex: "5cb87a")!     // jade — producing
    static let graphPatch = Color(hex: "e07a5f")!     // terracotta — changing
    static let graphTerminal = Color(hex: "9d7cff")!  // violet — executing
    static let graphReasoning = Color(hex: "8a8f98")! // slate — thinking
    static let graphOther = Color(hex: "7d8597")!     // gray-blue — misc
    /// Context-compaction "fold" rule. Deliberately a DESATURATED parchment —
    /// every tool color above is a saturated jewel tone, so a muted tan reads
    /// as chrome/structure (a seam in the timeline), not as another tool bar.
    /// RGB literal (not `Color(hex:)!`) to avoid a force-unwrap in new code —
    /// this is #cdb891.
    internal static let graphCompaction = Color(red: 0.804, green: 0.722, blue: 0.569)

    // MARK: - Borders
    static let border = Color(hex: "3a3a3a")!

    // MARK: - Dimensions
    static let bubbleRadius: CGFloat = 16
    static let bubblePaddingH: CGFloat = 20
    static let bubblePaddingV: CGFloat = 14
    static let pillRadius: CGFloat = 12
    static let pillSpacing: CGFloat = 10
    static let avatarSize: CGFloat = 48
    static let illustrationHeight: CGFloat = 260
}
