import Foundation

// MARK: - Reviewed-diff highlighting

/// What the canvas tints while a history row is open.
///
/// Split out of `CronGraphViewModel` because every property here is a pure
/// derivation from `reviewedDiff` plus what is currently drawn — no loading, no
/// physics, no selection. They belong together for a reason the main type can't
/// express: each one has to intersect the diff's statements with the on-screen
/// graph, and `reviewedChangesNotOnScreen` counts exactly what the others had to
/// drop. Reading them side by side is how you check that nothing is silently
/// omitted from the highlight.
extension CronGraphViewModel {

    /// Indices of on-screen nodes the reviewed diff touches — what the canvas
    /// tints.
    ///
    /// Derived from the diff's own statements and then intersected with what is
    /// actually drawn, in that order. Both halves matter: deriving it means the
    /// highlight can't drift from what the drawer lists, and intersecting means a
    /// job the change *deleted* doesn't get a highlight on a node that no longer
    /// exists. The count of statements it couldn't reach is
    /// `reviewedChangesNotOnScreen`, which the drawer says out loud rather than
    /// letting the graph imply it showed everything.
    internal var reviewedNodeIndices: Set<Int> {
        Set(reviewedNodePolarities.keys)
    }

    /// The same set, carrying how each node changed so the canvas can tint by
    /// polarity. `reviewedNodeIndices` is its key set rather than a second walk of
    /// the diff — the highlight and its colors are then one derivation, and a node
    /// can't be lit with no color or colored without being lit.
    internal var reviewedNodePolarities: [Int: CronGraphChange.Polarity] {
        guard let diff = reviewedDiff else { return [:] }
        let affected = diff.affectedNodeIDs
        return simNodes.indices.reduce(into: [:]) { result, index in
            let id = simNodes[index].id
            guard affected.contains(id), let polarity = diff.polarity(forNodeID: id) else { return }
            result[index] = polarity
        }
    }

    /// Link indices for edges the reviewed diff added — drawn lit rather than
    /// dimmed with the rest of the graph.
    internal var reviewedAddedLinkIndices: Set<Int> {
        guard let diff = reviewedDiff, !diff.addedEdgeIDs.isEmpty else { return [] }
        return Set(simLinks.indices.filter { index in
            let (si, ti) = simLinks[index]
            guard simNodes.indices.contains(si), simNodes.indices.contains(ti),
                  index < simLinkTypes.count else { return false }
            let edge = CronGraphEdge(source: simNodes[si].id, target: simNodes[ti].id,
                                     type: simLinkTypes[index])
            return diff.addedEdgeIDs.contains(edge.id)
        })
    }

    /// Edges the reviewed diff removed, resolved to on-screen positions so the
    /// canvas can ghost them back in. Both endpoints have to still exist — a
    /// removed edge between two deleted nodes has nowhere to be drawn.
    internal var reviewedRemovedLinks: [(sourceIndex: Int, targetIndex: Int, type: String)] {
        guard let diff = reviewedDiff else { return [] }
        let indexByID = Dictionary(simNodes.enumerated().map { ($1.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        return diff.removedEdges.compactMap { edge in
            guard let si = indexByID[edge.source], let ti = indexByID[edge.target] else { return nil }
            return (sourceIndex: si, targetIndex: ti, type: edge.type)
        }
    }

    /// How many of the reviewed diff's statements name nothing currently drawn.
    ///
    /// Reviewing an old revision highlights against the *current* wiring, so a
    /// change to a job that has since been deleted has no node to tint. The number
    /// exists so the surface can admit that instead of showing a partial highlight
    /// as if it were the whole change.
    internal var reviewedChangesNotOnScreen: Int {
        guard let diff = reviewedDiff else { return 0 }
        let onScreen = Set(simNodes.map(\.id))
        return diff.changes.filter { change in
            !change.nodeIDs.contains { onScreen.contains($0) }
        }.count
    }
}
