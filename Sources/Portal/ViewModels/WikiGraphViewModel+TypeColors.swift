import SwiftUI

// MARK: - Hierarchical type colors
//
// Page types are author-defined and can be hierarchical folder paths like
// "entities/chain/base". The fixed `color(for:)` switch only knows the flat
// hermes/Centaur kinds, so every nested type used to fall through to grey —
// "entities/chain/base", ".../solana", ".../tempo" were all indistinguishable.
// Here we group nested types by their parent branch ("entities/chain") and give
// each distinct branch in the graph its own, unique hue.

extension WikiGraphViewModel {

    /// The parent branch of a hierarchical type — "entities/chain/base" →
    /// "entities/chain" — or nil for a flat type like "entity" with no "/".
    /// The branch is the grouping key: siblings under it share one color.
    internal static func branchKey(for type: String) -> String? {
        let parts = type.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    /// Color for a type outside the fixed known set: a hierarchical type resolves
    /// to its branch's color from the per-graph palette; a flat unknown type
    /// keeps the neutral grey.
    internal func nestedColor(for type: String) -> Color {
        if let branch = Self.branchKey(for: type), let color = nestedTypeColors[branch] {
            return color
        }
        return Color(hex: "aaaaaa") ?? .gray
    }

    /// Give every distinct nested branch in the current graph its own hue, evenly
    /// spaced around the wheel so no two branches ever collide — the whole point
    /// being that "entities/chain/*" no longer collapses to grey. Called from
    /// `graph.didSet`.
    internal func rebuildNestedTypeColors() {
        let branches = Set(graph.pages.compactMap { Self.branchKey(for: $0.type) }).sorted()
        guard !branches.isEmpty else { nestedTypeColors = [:]; return }
        var map: [String: Color] = [:]
        for (offset, branch) in branches.enumerated() {
            let hue = Double(offset) / Double(branches.count)
            map[branch] = Color(hue: hue, saturation: 0.62, brightness: 0.9)
        }
        nestedTypeColors = map
    }
}
