import SwiftUI

/// The colours the Extraction map draws with: one per rule family (so a wire
/// says which kind of rule produced the extraction), plus the quiet stroke for
/// bundles that mix families. Fixed hex values rather than theme tokens so the
/// legend reads the same in every theme, as on the web observatory.
internal enum ArchitectureExtractionPalette {
    internal static func color(for family: ArchitectureExtractionFamily) -> Color {
        switch family {
        case .store: return Color(red: 0.49, green: 0.78, blue: 0.69)
        case .behaviour: return Color(red: 0.55, green: 0.51, blue: 1.0)
        case .boundary: return Color(red: 0.88, green: 0.44, blue: 0.31)
        case .wiring: return Color(red: 0.85, green: 0.64, blue: 0.25)
        case .trigger: return Color(red: 0.35, green: 0.66, blue: 0.90)
        case .custom: return Theme.secondary
        }
    }

    /// A bundle's stroke: its one family's colour, or the quiet mixed stroke.
    internal static func color(for bundle: ArchitectureExtractionLayout.WireBundle) -> Color {
        bundle.family.map(color(for:)) ?? Theme.tertiary
    }

    /// Cell fill for a file: the accent at an opacity that grows with the share
    /// of its declarations the extractor placed.
    internal static func cellOpacity(share: Double) -> Double {
        0.16 + 0.74 * min(1, max(0, share))
    }
}

extension View {
    /// The Extraction map's monospaced text at one of its three sizes, re-asserting
    /// the design against the app-wide typeface as the architecture rules require.
    internal func extractionMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced)).monospaced()
    }
}
