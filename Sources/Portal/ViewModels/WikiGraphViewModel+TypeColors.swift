import SwiftUI

// MARK: - Folder-branch colors
//
// A page's `type` is author-defined but, in real compendia, flat: "org",
// "chain", "meta". The hierarchy lives entirely in the file `path`
// ("entities/chain/base.md", "entities/org/0x.md"). So the graph groups nodes
// by their folder branch ("entities/chain") and gives each distinct branch its
// own hue — otherwise the hundreds of flat-typed nodes all collapse to grey.

extension WikiGraphViewModel {

    /// The folder a page lives in, used as its color group: the path's directory
    /// with the filename dropped — "entities/chain/base.md" → "entities/chain".
    /// Nil for a root-level page ("index.md") that has no folder. Pages sharing a
    /// folder share a hue.
    internal static func branchKey(for path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    /// Give every distinct folder branch in the current graph its own hue, evenly
    /// spaced around the wheel so no two families collide — the whole point being
    /// that "entities/chain/*" no longer collapses to grey. Called from
    /// `graph.didSet`.
    internal func rebuildNestedTypeColors() {
        let branches = Set(graph.pages.compactMap { Self.branchKey(for: $0.path) }).sorted()
        guard !branches.isEmpty else { nestedTypeColors = [:]; return }
        var map: [String: Color] = [:]
        for (offset, branch) in branches.enumerated() {
            let hue = Double(offset) / Double(branches.count)
            map[branch] = Color(hue: hue, saturation: 0.62, brightness: 0.9)
        }
        nestedTypeColors = map
    }
}
