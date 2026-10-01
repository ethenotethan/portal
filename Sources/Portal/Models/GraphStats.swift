import Foundation

/// Counts and structure of a graph the app draws — nodes, edges, components,
/// degrees — plus the extras a particular graph can say about itself. A pure
/// value: computed once per graph change by the view model that owns the
/// graph and cached there (never in a `body`; see the per-render parse rule in
/// docs/architecture-rules.md), so the panel that shows it is an `Equatable`
/// value view over the result.
internal struct GraphStats: Equatable {
    /// One labelled count, sorted for display.
    internal struct Row: Equatable, Identifiable {
        internal let label: String
        internal let count: Int
        internal var id: String { label }
    }

    /// A titled block of rows: the shared blocks and each graph's extras.
    internal struct Section: Equatable, Identifiable {
        internal let title: String
        internal let rows: [Row]
        internal var id: String { title }
    }

    internal struct Degree: Equatable {
        internal let label: String
        internal let degree: Int
    }

    /// The shape every graph reduces to before counting.
    internal struct Node: Equatable {
        internal let id: String
        internal let label: String
        internal let kind: String
    }

    internal struct Edge: Equatable {
        internal let source: String
        internal let target: String
        internal let type: String
    }

    internal let nodeCount: Int
    internal let edgeCount: Int
    internal let nodesByKind: [Row]
    internal let edgesByType: [Row]
    /// Connected components over the nodes, counting edges whose both ends are nodes.
    internal let components: Int
    /// Nodes no edge touches.
    internal let isolatedNodes: Int
    internal let maxDegree: Degree?
    /// Mean degree: twice the connected edges over the node count.
    internal let averageDegree: Double
    /// Edges whose source or target is not a node of this graph.
    internal let danglingEdges: Int
    internal let extras: [Section]

    internal static let empty = GraphStats(
        nodeCount: 0, edgeCount: 0, nodesByKind: [], edgesByType: [], components: 0,
        isolatedNodes: 0, maxDegree: nil, averageDegree: 0, danglingEdges: 0, extras: []
    )

    /// How many rows of a breakdown the panel shows before the rest folds into "other".
    internal static let breakdownLimit = 6

    /// The first `breakdownLimit` rows, the remainder summed as one "other" row.
    internal static func folded(_ rows: [Row], limit: Int = breakdownLimit) -> [Row] {
        guard rows.count > limit else { return rows }
        let rest = rows.dropFirst(limit).reduce(0) { $0 + $1.count }
        return Array(rows.prefix(limit)) + [Row(label: "other (\(rows.count - limit))", count: rest)]
    }

    /// Counts sorted by size then label, so the panel reads the same on every render.
    internal static func rows(_ counts: [String: Int]) -> [Row] {
        counts.map { Row(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in lhs.count != rhs.count ? lhs.count > rhs.count : lhs.label < rhs.label }
    }

    internal static func compute(nodes: [Node], edges: [Edge], extras: [Section] = []) -> GraphStats {
        var index: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() where index[node.id] == nil {
            index[node.id] = offset
        }
        var parent = Array(0..<nodes.count)
        func root(_ item: Int) -> Int {
            var current = item
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        var degree = [Int](repeating: 0, count: nodes.count)
        var connected = 0
        var dangling = 0
        var kinds: [String: Int] = [:]
        var types: [String: Int] = [:]
        for node in nodes {
            kinds[node.kind, default: 0] += 1
        }
        for edge in edges {
            types[edge.type, default: 0] += 1
            guard let source = index[edge.source], let target = index[edge.target] else {
                dangling += 1
                continue
            }
            connected += 1
            degree[source] += 1
            if source != target {
                degree[target] += 1
            }
            let left = root(source)
            let right = root(target)
            if left != right {
                parent[left] = right
            }
        }
        var roots = Set<Int>()
        for offset in 0..<nodes.count where index[nodes[offset].id] == offset {
            roots.insert(root(offset))
        }
        var top: Degree?
        var isolated = 0
        for (offset, node) in nodes.enumerated() where index[node.id] == offset {
            if degree[offset] == 0 { isolated += 1 }
            if top == nil || degree[offset] > (top?.degree ?? -1) {
                top = Degree(label: node.label, degree: degree[offset])
            }
        }
        let uniqueNodes = index.count
        return GraphStats(
            nodeCount: uniqueNodes,
            edgeCount: edges.count,
            nodesByKind: rows(kinds),
            edgesByType: rows(types),
            components: roots.count,
            isolatedNodes: isolated,
            maxDegree: top,
            averageDegree: uniqueNodes == 0 ? 0 : Double(2 * connected) / Double(uniqueNodes),
            danglingEdges: dangling,
            extras: extras
        )
    }
}

// MARK: - The graphs Portal draws

extension GraphStats {
    /// A wiki: pages are nodes typed by their page type, links are edges typed
    /// by relationship. Extras are what the wiki knows beyond structure.
    internal static func wiki(_ graph: WikiGraph, pinnedCount: Int) -> GraphStats {
        let nodes = graph.pages.map { Node(id: $0.id, label: $0.title, kind: $0.type) }
        let edges = graph.links.map { Edge(source: $0.source, target: $0.target, type: $0.type) }
        let tags = Set(graph.pages.flatMap(\.tags))
        let extras = [Section(title: "Wiki", rows: [
            Row(label: "Pinned pages", count: pinnedCount),
            Row(label: "Contested pages", count: graph.pages.filter(\.contested).count),
            Row(label: "Untagged pages", count: graph.pages.filter { $0.tags.isEmpty && $0.tagPath.isEmpty }.count),
            Row(label: "Distinct tags", count: tags.count),
            Row(label: "Integration links", count: graph.pages.reduce(0) { $0 + $1.integrationLinks.count }),
        ])]
        return compute(nodes: nodes, edges: edges, extras: extras)
    }

    /// The runtime dataflow: cron jobs, services, resources and sinks, wired by
    /// the edge types the gateway declares. Extras come from the runtime.
    internal static func cron(_ graph: CronGraph, collapsedGroups: Int, revisionCount: Int) -> GraphStats {
        let nodes = graph.nodes.map { Node(id: $0.id, label: $0.label, kind: $0.kind) }
        let edges = graph.edges.map { Edge(source: $0.source, target: $0.target, type: $0.type) }
        let jobs = graph.nodes.filter { $0.kind == "cron" }
        let services = graph.nodes.filter { $0.kind == "service" }
        var providers: [String: Int] = [:]
        for service in services {
            providers[Self.provider(ofServiceID: service.id), default: 0] += 1
        }
        let healthy = services.filter { $0.health?.status == "healthy" }.count
        let unprobed = services.filter { $0.health == nil }.count
        let runtime = Section(title: "Runtime", rows: [
            Row(label: "Jobs", count: jobs.count),
            Row(label: "Enabled jobs", count: jobs.filter(\.enabled).count),
            Row(label: "Jobs using an LLM", count: jobs.filter(\.usesLLM).count),
            Row(label: "Services", count: services.count),
            Row(label: "Healthy services", count: healthy),
            Row(label: "Unhealthy services", count: services.count - healthy - unprobed),
            Row(label: "Unprobed services", count: unprobed),
            Row(label: "Collapsed groups", count: collapsedGroups),
            Row(label: "Revisions", count: revisionCount),
        ])
        let byProvider = Section(title: "Services by provider", rows: rows(providers))
        return compute(nodes: nodes, edges: edges, extras: [runtime, byProvider])
    }

    /// The provider a runtime service id encodes: `launchd:<label>`, `docker:<id>`,
    /// `nomad:<job>`, `arch:<manifest>`, `proc_<handle>` or a bare process id.
    internal static func provider(ofServiceID id: String) -> String {
        if id.hasPrefix("proc_") { return "process" }
        if let colon = id.firstIndex(of: ":") {
            let prefix = String(id[..<colon])
            return prefix == "arch" ? "architecture" : prefix
        }
        return "process"
    }

    /// The architecture system map: constructions by kind, edges by class,
    /// with the map's own declarations as extras.
    internal static func systemMap(_ document: ArchitectureSystemMapDocument, hullCount: Int) -> GraphStats {
        let nodes = document.nodes.map { Node(id: $0.id, label: $0.label, kind: $0.kind.label) }
        let edges = document.edges.map { Edge(source: $0.source, target: $0.target, type: $0.edgeClass.rawValue) }
        var relations: [String: Int] = [:]
        for edge in document.edges {
            relations[edge.relation, default: 0] += 1
        }
        let map = Section(title: "Map", rows: [
            Row(label: "Hulls", count: hullCount),
            Row(label: "Pages", count: document.pages.count),
            Row(label: "Boundary groups", count: document.boundaryGroups.count),
            Row(label: "Clusters", count: document.clusters.count),
            Row(label: "Flows", count: document.flows.count),
            Row(label: "Invariants holding", count: document.invariants.filter { $0.status == "holds" }.count),
            Row(label: "Invariants", count: document.invariants.count),
        ])
        return compute(nodes: nodes, edges: edges, extras: [map, Section(title: "Relations", rows: rows(relations))])
    }
}
