import Foundation
import CoreGraphics

// MARK: - Hull tree: what contains what on the system map

/// The kinds of box the map draws around constructions.
internal enum ArchitectureHullKind: Hashable {
    /// The application boundary: the outermost hull, holding the pages.
    case application
    /// A navigation page inside the application (or the shared core).
    case page
    /// The constructions one owner type holds, inside a page.
    case cluster
    /// A boundary group outside the application (platform storage, on-device inference).
    case boundary
    /// A storage system drawn as a container of the artifacts stored in it.
    case container
    /// A backend drawn as a box of the endpoint namespaces it serves.
    case gateway
    /// External systems that belong to no declared boundary group.
    case externals
}

internal struct ArchitectureHull: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let kind: ArchitectureHullKind
    internal let parent: String?
    internal var childHullIDs: [String]
    internal var nodeIDs: [String]
    /// The external node this hull stands for (containers and gateways): the
    /// node is never drawn on its own, edges to it end at the hull.
    internal let representsNodeID: String?
}

/// Every construction placed in exactly one hull path, root to innermost.
/// Deterministic for a given document: the same map builds the same tree.
internal struct ArchitectureHullTree: Hashable {
    internal static let applicationID = "hull:application"
    internal static let sharedPageID = "hull:page:shared"
    internal static let externalsID = "hull:externals"

    internal let hulls: [String: ArchitectureHull]
    /// Root hulls in drawing order: boundaries, free externals, the application, gateways.
    internal let rootIDs: [String]
    /// The innermost hull each drawn node sits in.
    internal let hullOfNode: [String: String]
    /// Nodes a hull stands for (container and gateway externals).
    internal let representedBy: [String: String]

    internal func hull(_ id: String) -> ArchitectureHull? {
        hulls[id]
    }

    /// Root → innermost hull ids around a node; a represented node's path ends at its hull.
    internal func path(toNode nodeID: String) -> [String] {
        if let hullID = representedBy[nodeID] { return path(toHull: hullID) }
        guard let hullID = hullOfNode[nodeID] else { return [] }
        return path(toHull: hullID)
    }

    internal func path(toHull hullID: String) -> [String] {
        var chain: [String] = []
        var cursor: String? = hullID
        while let current = cursor, let hull = hulls[current] {
            chain.append(current)
            cursor = hull.parent
        }
        return chain.reversed()
    }

    /// Every node inside a hull, at any depth, plus the node it stands for.
    internal func descendantNodeIDs(of hullID: String) -> [String] {
        guard let hull = hulls[hullID] else { return [] }
        var result = hull.nodeIDs
        if let represented = hull.representsNodeID { result.append(represented) }
        for child in hull.childHullIDs { result += descendantNodeIDs(of: child) }
        return result
    }

    internal func constructionCount(of hullID: String) -> Int {
        descendantNodeIDs(of: hullID).count
    }

    internal static func build(from document: ArchitectureSystemMapDocument) -> ArchitectureHullTree {
        var builder = Builder(document: document)
        builder.run()
        return ArchitectureHullTree(
            hulls: builder.hulls, rootIDs: builder.orderedRoots(), hullOfNode: builder.hullOfNode, representedBy: builder.representedBy
        )
    }

    private struct Builder {
        let document: ArchitectureSystemMapDocument
        var hulls: [String: ArchitectureHull] = [:]
        var roots: [String] = []
        var hullOfNode: [String: String] = [:]
        var representedBy: [String: String] = [:]
        private var servedBy: [String: String] = [:]
        private var storedIn: [String: String] = [:]
        private var boundaryOf: [String: String] = [:]
        private var clusterSize: [String: Int] = [:]
        private var clusterPage: [String: String] = [:]

        init(document: ArchitectureSystemMapDocument) {
            self.document = document
            let externalIDs = Set(document.nodes.filter { $0.kind == .external }.map(\.id))
            for edge in document.edges where externalIDs.contains(edge.target) {
                if edge.relation == "served-by" { servedBy[edge.source] = edge.target }
                if edge.relation == "stored-in" { storedIn[edge.source] = edge.target }
            }
            for group in document.boundaryGroups {
                for member in group.members { boundaryOf[member] = group.id }
            }
            // Clusters are hulls only when two or more page-resident constructions share one.
            var pagesByCluster: [String: [String]] = [:]
            for node in document.nodes where placesInPage(node) {
                guard let cluster = node.cluster else { continue }
                clusterSize[cluster, default: 0] += 1
                pagesByCluster[cluster, default: []].append(pageID(for: node))
            }
            for (cluster, pages) in pagesByCluster {
                var counts: [String: Int] = [:]
                for page in pages { counts[page, default: 0] += 1 }
                clusterPage[cluster] = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            }
        }

        private func placesInPage(_ node: ArchitectureMapNode) -> Bool {
            switch node.kind {
            case .external: return false
            case .endpoint: return servedBy[node.id] == nil
            case .artifact: return storedIn[node.id] == nil
            default: return true
            }
        }

        private func pageID(for node: ArchitectureMapNode) -> String {
            if let page = node.page, document.pageIDs.contains(page) { return page }
            return "shared"
        }

        private mutating func ensure(_ id: String, label: String, kind: ArchitectureHullKind, parent: String?, represents: String? = nil) {
            guard hulls[id] == nil else { return }
            hulls[id] = ArchitectureHull(id: id, label: label, kind: kind, parent: parent, childHullIDs: [], nodeIDs: [], representsNodeID: represents)
            if let parent {
                hulls[parent]?.childHullIDs.append(id)
            } else {
                roots.append(id)
            }
            if let represents { representedBy[represents] = id }
        }

        private mutating func place(_ nodeID: String, in hullID: String) {
            hulls[hullID]?.nodeIDs.append(nodeID)
            hullOfNode[nodeID] = hullID
        }

        private mutating func ensureBoundaryParent(forExternal externalID: String) -> String {
            if let group = boundaryOf[externalID], let declared = document.boundaryGroups.first(where: { $0.id == group }) {
                let id = "hull:boundary:\(group)"
                ensure(id, label: declared.label, kind: .boundary, parent: nil)
                return id
            }
            ensure(ArchitectureHullTree.externalsID, label: "External systems", kind: .externals, parent: nil)
            return ArchitectureHullTree.externalsID
        }

        private mutating func ensureContainer(forExternal externalID: String) -> String {
            let parent = ensureBoundaryParent(forExternal: externalID)
            let id = "hull:container:\(externalID)"
            let label = document.node(id: externalID)?.label ?? externalID
            ensure(id, label: label, kind: .container, parent: parent, represents: externalID)
            return id
        }

        private mutating func ensureGateway(forExternal externalID: String) -> String {
            let id = "hull:gateway:\(externalID)"
            let label = document.node(id: externalID)?.label ?? externalID
            ensure(id, label: label, kind: .gateway, parent: nil, represents: externalID)
            return id
        }

        private mutating func ensurePage(_ pageID: String) -> String {
            ensure(ArchitectureHullTree.applicationID, label: "Portal application", kind: .application, parent: nil)
            let id = pageID == "shared" ? ArchitectureHullTree.sharedPageID : "hull:page:\(pageID)"
            let label = document.pages.first { $0.id == pageID }?.label ?? "Shared core"
            ensure(id, label: label, kind: .page, parent: ArchitectureHullTree.applicationID)
            return id
        }

        mutating func run() {
            let gatewayExternals = Set(servedBy.values)
            let containerExternals = Set(storedIn.values)
            for node in document.nodes {
                switch node.kind {
                case .external where gatewayExternals.contains(node.id):
                    _ = ensureGateway(forExternal: node.id)
                case .external where containerExternals.contains(node.id):
                    _ = ensureContainer(forExternal: node.id)
                case .external:
                    place(node.id, in: ensureBoundaryParent(forExternal: node.id))
                case .endpoint where servedBy[node.id] != nil:
                    if let external = servedBy[node.id] { place(node.id, in: ensureGateway(forExternal: external)) }
                case .artifact where storedIn[node.id] != nil:
                    if let external = storedIn[node.id] { place(node.id, in: ensureContainer(forExternal: external)) }
                default:
                    let page = ensurePage(pageID(for: node))
                    if let cluster = node.cluster, (clusterSize[cluster] ?? 0) >= 2 {
                        let clusterPageID = ensurePage(clusterPage[cluster] ?? pageID(for: node))
                        let declared = document.clusters.first { $0.id == cluster }
                        let label = declared?.ownerType ?? declared?.component ?? node.ownerType ?? "Cluster"
                        let id = "hull:cluster:\(cluster)"
                        ensure(id, label: label, kind: .cluster, parent: clusterPageID)
                        place(node.id, in: id)
                    } else {
                        place(node.id, in: page)
                    }
                }
            }
            // Pages follow the document's page order; the shared core comes last.
            if var application = hulls[ArchitectureHullTree.applicationID] {
                let order = Dictionary(uniqueKeysWithValues: document.pages.enumerated().map { ("hull:page:\($1.id)", $0) })
                application.childHullIDs.sort { (order[$0] ?? Int.max) < (order[$1] ?? Int.max) }
                hulls[ArchitectureHullTree.applicationID] = application
            }
        }

        func orderedRoots() -> [String] {
            let rank: (String) -> Int = { id in
                switch hulls[id]?.kind {
                case .boundary: return 0
                case .externals: return 1
                case .application: return 2
                default: return 3
                }
            }
            return roots.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : ($0 < $1) }
        }
    }
}

// MARK: - Layout: frames for what is visible, edges bundled onto it

internal enum ArchitectureMapElement: Hashable {
    case node(String)
    case hull(String)

    internal var id: String {
        switch self {
        case .node(let id): return id
        case .hull(let id): return id
        }
    }

    internal var isHull: Bool {
        if case .hull = self { return true }
        return false
    }
}

internal struct ArchitectureMapFrame: Hashable {
    internal let element: ArchitectureMapElement
    internal let frame: CGRect
    /// Nesting depth: roots are 0, their nodes 1, and so on. Deeper draws later.
    internal let depth: Int
    /// A hull drawn as its closed box (its contents hidden).
    internal let collapsed: Bool
}

/// The edges between two visible elements, drawn once with their count.
internal struct ArchitectureMapBundle: Hashable, Identifiable {
    internal let id: String
    internal let source: ArchitectureMapElement
    internal let target: ArchitectureMapElement
    internal let edgeIndices: [Int]
    internal let relations: [String]
    internal let classes: [ArchitectureEdgeClass]

    internal var count: Int { edgeIndices.count }
    /// One class when every edge in the bundle agrees, else nil (drawn quiet).
    internal var uniformClass: ArchitectureEdgeClass? { classes.count == 1 ? classes[0] : nil }
}

/// A deterministic layout of the hull tree for one expansion state. Pure value:
/// build it, read frames and bundles, hit-test points. Nothing here touches SwiftUI.
internal struct ArchitectureSystemMapLayout: Hashable {
    internal static let nodeSize = CGSize(width: 148, height: 34)
    internal static let collapsedHullSize = CGSize(width: 216, height: 58)
    internal static let headerHeight: CGFloat = 26
    internal static let padding: CGFloat = 12
    internal static let gap: CGFloat = 10
    internal static let margin: CGFloat = 24
    internal static let columnGap: CGFloat = 56

    internal let tree: ArchitectureHullTree
    internal let expanded: Set<String>
    internal let frames: [ArchitectureMapFrame]
    internal private(set) var bundles: [ArchitectureMapBundle]
    internal let size: CGSize
    private let frameByElement: [ArchitectureMapElement: CGRect]

    internal func frame(of element: ArchitectureMapElement) -> CGRect? {
        frameByElement[element]
    }

    /// The visible element that stands for a node: the outermost collapsed hull
    /// on its path, the container or gateway hull it is represented by, or itself.
    internal func representative(ofNode nodeID: String) -> ArchitectureMapElement? {
        let path = tree.path(toNode: nodeID)
        guard !path.isEmpty else { return nil }
        for hullID in path where !expanded.contains(hullID) {
            return .hull(hullID)
        }
        if let hullID = tree.representedBy[nodeID] { return .hull(hullID) }
        return .node(nodeID)
    }

    /// The innermost element under a point: nodes before the hulls around them.
    internal func hitTest(_ point: CGPoint) -> ArchitectureMapElement? {
        frames.sorted { $0.depth > $1.depth }.first { $0.frame.contains(point) }?.element
    }

    /// Where a curve between two boxes leaves one and enters the other: the
    /// points on each border along the line between their centres.
    internal static func anchors(from source: CGRect, to target: CGRect) -> (start: CGPoint, end: CGPoint) {
        (start: borderPoint(of: source, towards: target), end: borderPoint(of: target, towards: source))
    }

    private static func borderPoint(of rect: CGRect, towards other: CGRect) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = other.midX - center.x
        let dy = other.midY - center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    /// Shelf packing: rows of children left to right, a new row when the target
    /// width is reached. Deterministic; the target width keeps hulls roughly square.
    internal static func pack(_ sizes: [CGSize]) -> (origins: [CGPoint], size: CGSize) {
        guard !sizes.isEmpty else { return ([], .zero) }
        let area = sizes.reduce(CGFloat.zero) { $0 + ($1.width + gap) * ($1.height + gap) }
        let widest = sizes.map(\.width).max() ?? 0
        let target = max(widest, (area.squareRoot() * 1.35).rounded(.up))
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for size in sizes {
            if x > 0 && x + size.width > target {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - gap)
        }
        return (origins, CGSize(width: width, height: y + rowHeight))
    }

    internal static func layout(
        document: ArchitectureSystemMapDocument,
        tree: ArchitectureHullTree,
        expanded: Set<String>
    ) -> ArchitectureSystemMapLayout {
        var placer = Placer(tree: tree, expanded: expanded)
        let size = placer.placeRoots()
        return ArchitectureSystemMapLayout(tree: tree, expanded: expanded, frames: placer.frames, size: size, edges: document.edges)
    }

    private init(tree: ArchitectureHullTree, expanded: Set<String>, frames: [ArchitectureMapFrame], size: CGSize, edges: [ArchitectureMapEdge]) {
        self.tree = tree
        self.expanded = expanded
        self.frames = frames
        self.size = size
        frameByElement = Dictionary(frames.map { ($0.element, $0.frame) }, uniquingKeysWith: { first, _ in first })
        bundles = []
        bundles = bundled(edges)
    }

    private func bundled(_ edges: [ArchitectureMapEdge]) -> [ArchitectureMapBundle] {
        struct Entry {
            let source: ArchitectureMapElement
            let target: ArchitectureMapElement
            var indices: [Int] = []
            var relations: Set<String> = []
            var classes: Set<ArchitectureEdgeClass> = []
        }
        var grouped: [String: Entry] = [:]
        for (index, edge) in edges.enumerated() {
            guard let source = representative(ofNode: edge.source), let target = representative(ofNode: edge.target), source != target else { continue }
            // Containment is drawn as containment, never as an arrow into the box around you.
            if case .hull(let hull) = target, tree.path(toNode: edge.source).contains(hull) { continue }
            if case .hull(let hull) = source, tree.path(toNode: edge.target).contains(hull) { continue }
            let key = "\(source.id)→\(target.id)"
            var entry = grouped[key] ?? Entry(source: source, target: target)
            entry.indices.append(index)
            entry.relations.insert(edge.relation)
            entry.classes.insert(edge.edgeClass)
            grouped[key] = entry
        }
        return grouped.sorted { $0.key < $1.key }.map { key, entry in
            ArchitectureMapBundle(
                id: key, source: entry.source, target: entry.target, edgeIndices: entry.indices,
                relations: entry.relations.sorted(), classes: entry.classes.sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    private struct Placer {
        let tree: ArchitectureHullTree
        let expanded: Set<String>
        var frames: [ArchitectureMapFrame] = []
        private var measured: [String: CGSize] = [:]

        init(tree: ArchitectureHullTree, expanded: Set<String>) {
            self.tree = tree
            self.expanded = expanded
        }

        private func children(of hull: ArchitectureHull) -> [ArchitectureMapElement] {
            hull.childHullIDs.map(ArchitectureMapElement.hull) + hull.nodeIDs.map(ArchitectureMapElement.node)
        }

        mutating func measure(_ hullID: String) -> CGSize {
            if let known = measured[hullID] { return known }
            guard let hull = tree.hull(hullID) else { return .zero }
            let size: CGSize
            if !expanded.contains(hullID) {
                size = collapsedHullSize
            } else {
                let sizes = children(of: hull).map { element -> CGSize in
                    switch element {
                    case .hull(let id): return measure(id)
                    case .node: return nodeSize
                    }
                }
                let packed = pack(sizes).size
                size = CGSize(
                    width: max(packed.width, collapsedHullSize.width) + padding * 2,
                    height: packed.height + headerHeight + padding * 2
                )
            }
            measured[hullID] = size
            return size
        }

        mutating func place(_ hullID: String, at origin: CGPoint, depth: Int) {
            guard let hull = tree.hull(hullID) else { return }
            let size = measure(hullID)
            let collapsed = !expanded.contains(hullID)
            frames.append(ArchitectureMapFrame(element: .hull(hullID), frame: CGRect(origin: origin, size: size), depth: depth, collapsed: collapsed))
            guard !collapsed else { return }
            let elements = children(of: hull)
            let sizes = elements.map { element -> CGSize in
                switch element {
                case .hull(let id): return measure(id)
                case .node: return nodeSize
                }
            }
            let packed = pack(sizes)
            let inner = CGPoint(x: origin.x + padding, y: origin.y + headerHeight + padding)
            for (element, offset) in zip(elements, packed.origins) {
                let point = CGPoint(x: inner.x + offset.x, y: inner.y + offset.y)
                switch element {
                case .hull(let id):
                    place(id, at: point, depth: depth + 1)
                case .node(let id):
                    frames.append(ArchitectureMapFrame(element: .node(id), frame: CGRect(origin: point, size: nodeSize), depth: depth + 1, collapsed: false))
                }
            }
        }

        /// Boundaries and free externals in a left column, the application beside
        /// them, gateways beneath the application.
        mutating func placeRoots() -> CGSize {
            let left = tree.rootIDs.filter { [.boundary, .externals].contains(tree.hull($0)?.kind) }
            let middle = tree.rootIDs.filter { tree.hull($0)?.kind == .application }
            let bottom = tree.rootIDs.filter { ![.boundary, .externals, .application].contains(tree.hull($0)?.kind) }
            var y = margin
            var leftWidth: CGFloat = 0
            for id in left {
                let size = measure(id)
                place(id, at: CGPoint(x: margin, y: y), depth: 0)
                y += size.height + columnGap
                leftWidth = max(leftWidth, size.width)
            }
            let leftBottom = y - columnGap
            let applicationX = left.isEmpty ? margin : margin + leftWidth + columnGap
            var applicationBottom = margin
            var rightEdge = applicationX
            for id in middle {
                let size = measure(id)
                place(id, at: CGPoint(x: applicationX, y: margin), depth: 0)
                applicationBottom = margin + size.height
                rightEdge = max(rightEdge, applicationX + size.width)
            }
            var x = applicationX
            var bottomHeight: CGFloat = 0
            for id in bottom {
                let size = measure(id)
                place(id, at: CGPoint(x: x, y: applicationBottom + columnGap), depth: 0)
                x += size.width + columnGap
                bottomHeight = max(bottomHeight, size.height)
                rightEdge = max(rightEdge, x - columnGap)
            }
            let bottomEdge = bottom.isEmpty ? applicationBottom : applicationBottom + columnGap + bottomHeight
            return CGSize(width: rightEdge + margin, height: max(leftBottom, bottomEdge) + margin)
        }
    }
}

// MARK: - Queries the surface asks of a map

internal enum ArchitectureSystemMapQueries {
    /// The edges that start or end at a node.
    internal static func edgeIndices(touching nodeID: String, in document: ArchitectureSystemMapDocument) -> Set<Int> {
        Set(document.edges.enumerated().compactMap { index, edge in
            edge.source == nodeID || edge.target == nodeID ? index : nil
        })
    }

    /// The map edges a flow walks: each step resolved to node ids and matched by
    /// source, target and relation. Steps that leave from a page pseudo-node have
    /// no edge on the map and light nothing.
    internal static func edgeIndices(for flow: ArchitectureFlow, in document: ArchitectureSystemMapDocument) -> Set<Int> {
        var wanted: Set<[String]> = []
        for step in flow.steps {
            guard case .node(let from) = document.resolve(stepEndpoint: step.from),
                  case .node(let to) = document.resolve(stepEndpoint: step.to) else { continue }
            wanted.insert([from, to, step.relation])
        }
        return Set(document.edges.enumerated().compactMap { index, edge in
            wanted.contains([edge.source, edge.target, edge.relation]) ? index : nil
        })
    }

    /// The nodes a flow visits, for revealing the hulls around them.
    internal static func nodeIDs(visitedBy flow: ArchitectureFlow, in document: ArchitectureSystemMapDocument) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for step in flow.steps {
            for reference in [step.from, step.to] {
                if case .node(let id) = document.resolve(stepEndpoint: reference), !seen.contains(id) {
                    seen.insert(id)
                    result.append(id)
                }
            }
        }
        return result
    }

    /// The nodes a search leaves lit: label, kind, component, owner or path
    /// containing the query, case-insensitively. Empty query lights everything.
    internal static func matchingNodeIDs(_ query: String, in document: ArchitectureSystemMapDocument) -> Set<String>? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return Set(document.nodes.filter { node in
            [node.label, node.kind.rawValue, node.component ?? "", node.ownerType ?? "", node.path ?? "", node.id]
                .contains { $0.lowercased().contains(needle) }
        }.map(\.id))
    }
}
