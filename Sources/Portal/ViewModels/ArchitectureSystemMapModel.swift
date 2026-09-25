import Foundation
import CoreGraphics
import Combine

/// Drives the native system map for one document: which hulls are open, what
/// is selected, the search, the edge colouring, the active flow, and the pan
/// and zoom of the canvas. Re-lays the map out whenever the expansion changes;
/// everything else is derived. Constructs no views.
@MainActor
internal final class ArchitectureSystemMapModel: ObservableObject {
    internal let document: ArchitectureSystemMapDocument
    internal let tree: ArchitectureHullTree

    @Published internal private(set) var expandedHulls: Set<String> = []
    @Published internal private(set) var layout: ArchitectureSystemMapLayout
    @Published internal private(set) var selectedNodeID: String?
    @Published internal private(set) var activeFlowID: String?
    @Published internal var searchText = ""
    @Published internal var coloursEdgesByRelation = false
    @Published internal var panOffset: CGSize = .zero
    @Published internal var zoom: CGFloat = 1

    internal static let minimumZoom: CGFloat = 0.25
    internal static let maximumZoom: CGFloat = 4

    internal init(document: ArchitectureSystemMapDocument) {
        self.document = document
        tree = ArchitectureHullTree.build(from: document)
        layout = ArchitectureSystemMapLayout.layout(document: document, tree: tree, expanded: [])
    }

    internal var selectedNode: ArchitectureMapNode? {
        selectedNodeID.flatMap(document.node(id:))
    }

    internal var activeFlow: ArchitectureFlow? {
        activeFlowID.flatMap { id in document.flows.first { $0.id == id } }
    }

    /// Edges lit on the map: the active flow's steps, plus the selected node's edges.
    internal var highlightedEdgeIndices: Set<Int> {
        var lit: Set<Int> = []
        if let flow = activeFlow { lit.formUnion(ArchitectureSystemMapQueries.edgeIndices(for: flow, in: document)) }
        if let node = selectedNodeID { lit.formUnion(ArchitectureSystemMapQueries.edgeIndices(touching: node, in: document)) }
        return lit
    }

    /// Nodes the search does not match; nil when there is no search.
    internal var dimmedNodeIDs: Set<String>? {
        guard let matching = ArchitectureSystemMapQueries.matchingNodeIDs(searchText, in: document) else { return nil }
        return Set(document.nodes.map(\.id)).subtracting(matching)
    }

    /// A node is dimmed when the search misses it; a hull when it misses every construction inside.
    internal func isDimmed(_ element: ArchitectureMapElement) -> Bool {
        guard let dimmed = dimmedNodeIDs else { return false }
        switch element {
        case .node(let id):
            return dimmed.contains(id)
        case .hull(let id):
            let inside = tree.descendantNodeIDs(of: id)
            return !inside.isEmpty && inside.allSatisfy(dimmed.contains)
        }
    }

    internal func isHighlighted(_ bundle: ArchitectureMapBundle) -> Bool {
        let lit = highlightedEdgeIndices
        return bundle.edgeIndices.contains(where: lit.contains)
    }

    internal func flows(involving nodeID: String) -> [ArchitectureFlow] {
        document.flows(involving: nodeID)
    }

    // MARK: Actions

    internal func toggleHull(_ hullID: String) {
        guard tree.hull(hullID) != nil else { return }
        if expandedHulls.contains(hullID) {
            // Closing a hull closes everything inside it, so reopening starts from its shell.
            for descendant in descendantHullIDs(of: hullID) { expandedHulls.remove(descendant) }
            expandedHulls.remove(hullID)
        } else {
            expandedHulls.insert(hullID)
        }
        relayout()
    }

    internal func expandAll() {
        expandedHulls = Set(tree.hulls.keys)
        relayout()
    }

    internal func collapseAll() {
        expandedHulls = []
        relayout()
    }

    /// Back to the whole map: everything closed, nothing selected, no flow, no search, identity view.
    internal func resetView() {
        selectedNodeID = nil
        activeFlowID = nil
        searchText = ""
        panOffset = .zero
        zoom = 1
        collapseAll()
    }

    internal func select(nodeID: String?) {
        selectedNodeID = selectedNodeID == nodeID ? nil : nodeID
    }

    /// A tap in content coordinates: a node selects, a hull toggles, empty space deselects.
    internal func handleTap(atContent point: CGPoint) {
        switch layout.hitTest(point) {
        case .node(let id):
            select(nodeID: id)
        case .hull(let id):
            toggleHull(id)
        case nil:
            selectedNodeID = nil
        }
    }

    /// Activate a flow (or clear it with nil), opening the hulls around every
    /// construction it visits so its steps are on screen.
    internal func setActiveFlow(_ flowID: String?) {
        guard let flowID, let flow = document.flows.first(where: { $0.id == flowID }) else {
            activeFlowID = nil
            return
        }
        activeFlowID = flowID
        var opened = false
        for nodeID in ArchitectureSystemMapQueries.nodeIDs(visitedBy: flow, in: document) {
            for hullID in tree.path(toNode: nodeID) where !expandedHulls.contains(hullID) {
                expandedHulls.insert(hullID)
                opened = true
            }
        }
        if opened { relayout() }
    }

    // MARK: Canvas geometry

    /// View point → content point under the current pan and zoom.
    internal func contentPoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - panOffset.width) / zoom, y: (point.y - panOffset.height) / zoom)
    }

    /// Zoom by a factor keeping the content under a view point fixed.
    internal func zoomAtPoint(factor: CGFloat, around viewPoint: CGPoint) {
        let target = min(max(zoom * factor, Self.minimumZoom), Self.maximumZoom)
        let applied = target / zoom
        guard applied != 1 else { return }
        panOffset = CGSize(
            width: viewPoint.x - (viewPoint.x - panOffset.width) * applied,
            height: viewPoint.y - (viewPoint.y - panOffset.height) * applied
        )
        zoom = target
    }

    /// Fit the whole layout into a viewport, centred.
    internal func fit(in viewport: CGSize) {
        guard layout.size.width > 0, layout.size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let scale = min(viewport.width / layout.size.width, viewport.height / layout.size.height, 1)
        zoom = max(scale, Self.minimumZoom)
        panOffset = CGSize(
            width: (viewport.width - layout.size.width * zoom) / 2,
            height: max((viewport.height - layout.size.height * zoom) / 2, 0)
        )
    }

    // MARK: Internals

    private func descendantHullIDs(of hullID: String) -> [String] {
        guard let hull = tree.hull(hullID) else { return [] }
        return hull.childHullIDs.flatMap { [$0] + descendantHullIDs(of: $0) }
    }

    private func relayout() {
        layout = ArchitectureSystemMapLayout.layout(document: document, tree: tree, expanded: expandedHulls)
    }
}
