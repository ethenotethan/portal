import Foundation

// MARK: - The `interplay` section of a hermes.architecture document, typed

/// What a construction on the system map is. Open: a newer compiler may emit a
/// kind this build does not know, which still decodes and still draws.
internal enum ArchitectureNodeKind: Hashable {
    case artifact
    case caller
    case client
    case endpoint
    case external
    case hub
    case machine
    case operation
    case owner
    case provider
    case resource
    case seam
    case section
    case store
    case subscriber
    case custom(String)

    private static let known: [String: ArchitectureNodeKind] = [
        "artifact": .artifact, "caller": .caller, "client": .client, "endpoint": .endpoint, "external": .external,
        "hub": .hub, "machine": .machine, "operation": .operation, "owner": .owner, "provider": .provider,
        "resource": .resource, "seam": .seam, "section": .section, "store": .store, "subscriber": .subscriber,
    ]

    internal init(rawValue: String) {
        self = Self.known[rawValue] ?? .custom(rawValue)
    }

    internal var rawValue: String {
        switch self {
        case .artifact: return "artifact"
        case .caller: return "caller"
        case .client: return "client"
        case .endpoint: return "endpoint"
        case .external: return "external"
        case .hub: return "hub"
        case .machine: return "machine"
        case .operation: return "operation"
        case .owner: return "owner"
        case .provider: return "provider"
        case .resource: return "resource"
        case .seam: return "seam"
        case .section: return "section"
        case .store: return "store"
        case .subscriber: return "subscriber"
        case .custom(let value): return value
        }
    }

    /// The legend's name for the kind.
    internal var label: String {
        switch self {
        case .artifact: return "Persisted artifact"
        case .caller: return "Calling surface"
        case .client: return "Client extension"
        case .endpoint: return "Queried endpoints"
        case .external: return "External system"
        case .hub: return "Interplay hub"
        case .machine: return "State machine"
        case .operation: return "Lifecycle operation"
        case .owner: return "Supporting owner"
        case .provider: return "Config provider"
        case .resource: return "Stored resource"
        case .seam: return "Backend seam"
        case .section: return "Critical section"
        case .store: return "Data store"
        case .subscriber: return "Event subscriber"
        case .custom(let value): return value
        }
    }

    /// Every kind the legend lists, in display order.
    internal static let legend: [ArchitectureNodeKind] = [
        .hub, .seam, .owner, .provider, .caller, .client, .endpoint, .section, .resource, .operation,
        .machine, .store, .artifact, .subscriber, .external,
    ]
}

/// The class of a map edge: how it is drawn and what the colour switch colours.
internal enum ArchitectureEdgeClass: Hashable {
    case structure
    case interplay
    case lifecycle
    case boundary
    case usage
    case custom(String)

    internal init(rawValue: String) {
        switch rawValue {
        case "structure": self = .structure
        case "interplay": self = .interplay
        case "lifecycle": self = .lifecycle
        case "boundary": self = .boundary
        case "usage": self = .usage
        default: self = .custom(rawValue)
        }
    }

    internal var rawValue: String {
        switch self {
        case .structure: return "structure"
        case .interplay: return "interplay"
        case .lifecycle: return "lifecycle"
        case .boundary: return "boundary"
        case .usage: return "usage"
        case .custom(let value): return value
        }
    }

    internal static let legend: [ArchitectureEdgeClass] = [.structure, .interplay, .lifecycle, .boundary, .usage]
}

internal struct ArchitectureMapNode: Hashable, Identifiable {
    internal let id: String
    internal let kind: ArchitectureNodeKind
    internal let label: String
    internal let subKind: String?
    internal let component: String?
    internal let page: String?
    internal let ownerType: String?
    internal let cluster: String?
    /// The identity that survives re-extraction; flow steps name nodes by it.
    internal let historyKey: String
    internal let path: String?
    internal let line: Int?
    /// The human-written construct record's summary, when one exists.
    internal let summary: String?
    internal let flowIDs: [String]

    /// `path:line` for the inspector, or nil when the node has no source site.
    internal var sourceSite: String? {
        guard let path else { return nil }
        return line.map { "\(path):\($0)" } ?? path
    }

    internal static func decode(_ value: AnyCodable) -> ArchitectureMapNode? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let semantic = d["semantic"]?.dictionaryValue
        return ArchitectureMapNode(
            id: id,
            kind: ArchitectureNodeKind(rawValue: d["kind"]?.stringValue ?? ""),
            label: d["label"]?.stringValue ?? id,
            subKind: d["sub_kind"]?.stringValue,
            component: d["component"]?.stringValue,
            page: d["page"]?.stringValue,
            ownerType: d["owner_type"]?.stringValue,
            cluster: d["cluster"]?.stringValue,
            historyKey: d["history_key"]?.stringValue ?? id,
            path: d["path"]?.stringValue,
            line: d["line"]?.intValue,
            summary: semantic?["summary"]?.stringValue,
            flowIDs: (d["flows"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

internal struct ArchitectureMapEdge: Hashable {
    internal let source: String
    internal let target: String
    internal let relation: String
    internal let edgeClass: ArchitectureEdgeClass

    internal static func decode(_ value: AnyCodable) -> ArchitectureMapEdge? {
        guard let d = value.dictionaryValue,
              let source = d["source"]?.stringValue, let target = d["target"]?.stringValue else { return nil }
        return ArchitectureMapEdge(
            source: source,
            target: target,
            relation: d["relation"]?.stringValue ?? "",
            edgeClass: ArchitectureEdgeClass(rawValue: d["class"]?.stringValue ?? "")
        )
    }
}

internal struct ArchitectureMapPage: Hashable, Identifiable {
    internal let id: String
    internal let label: String

    internal static func decode(_ value: AnyCodable) -> ArchitectureMapPage? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureMapPage(id: id, label: d["label"]?.stringValue ?? id)
    }
}

internal struct ArchitectureBoundaryGroup: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let members: [String]

    internal static func decode(_ value: AnyCodable) -> ArchitectureBoundaryGroup? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureBoundaryGroup(
            id: id,
            label: d["label"]?.stringValue ?? id,
            members: (d["members"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

internal struct ArchitectureMapCluster: Hashable, Identifiable {
    internal let id: String
    internal let component: String?
    internal let ownerType: String?

    internal static func decode(_ value: AnyCodable) -> ArchitectureMapCluster? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureMapCluster(id: id, component: d["component"]?.stringValue, ownerType: d["owner_type"]?.stringValue)
    }
}

internal struct ArchitectureFlowStep: Hashable {
    internal let from: String
    internal let to: String
    internal let relation: String
    internal let note: String

    internal static func decode(_ value: AnyCodable) -> ArchitectureFlowStep? {
        guard let d = value.dictionaryValue, let from = d["from"]?.stringValue, let to = d["to"]?.stringValue else { return nil }
        return ArchitectureFlowStep(from: from, to: to, relation: d["relation"]?.stringValue ?? "", note: d["note"]?.stringValue ?? "")
    }
}

internal struct ArchitectureFlow: Hashable, Identifiable {
    internal let id: String
    internal let title: String
    internal let summary: String
    internal let page: String?
    internal let journey: String
    internal let interaction: String
    internal let outcome: String
    internal let status: String
    internal let steps: [ArchitectureFlowStep]

    internal static func decode(_ value: AnyCodable) -> ArchitectureFlow? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureFlow(
            id: id,
            title: d["title"]?.stringValue ?? id,
            summary: d["summary"]?.stringValue ?? "",
            page: d["page"]?.stringValue,
            journey: d["journey"]?.stringValue ?? "",
            interaction: d["interaction"]?.stringValue ?? "",
            outcome: d["outcome"]?.stringValue ?? "",
            status: d["status"]?.stringValue ?? "",
            steps: (d["steps"]?.arrayValue ?? []).compactMap(ArchitectureFlowStep.decode)
        )
    }
}

internal struct ArchitectureInvariant: Hashable, Identifiable {
    internal let id: String
    internal let kind: String
    internal let status: String
    internal let why: String
    internal let checked: Int

    internal var holds: Bool { status == "holds" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureInvariant? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureInvariant(
            id: id,
            kind: d["kind"]?.stringValue ?? "",
            status: d["status"]?.stringValue ?? "",
            why: d["why"]?.stringValue ?? "",
            checked: d["checked"]?.intValue ?? 0
        )
    }
}

/// Where a flow step ends: a node (named by history key or id), a page's
/// pseudo-node (`page:<id>`), or something the map does not have.
internal enum ArchitectureFlowEndpoint: Hashable {
    case node(String)
    case page(String)
    case unknown(String)
}

/// The system map: every construction, the edges between them, the pages and
/// boundary groups that contain them, the flows that walk them and the
/// invariants that hold over them. Decoded tolerantly from the `interplay`
/// section; anything malformed is dropped, never fatal.
internal struct ArchitectureSystemMapDocument: Hashable {
    /// The model's title: what the application hull is called. Empty when the
    /// section was decoded on its own; the layout then says "Application".
    internal let title: String
    internal let nodes: [ArchitectureMapNode]
    internal let edges: [ArchitectureMapEdge]
    internal let pages: [ArchitectureMapPage]
    internal let boundaryGroups: [ArchitectureBoundaryGroup]
    internal let clusters: [ArchitectureMapCluster]
    internal let flows: [ArchitectureFlow]
    internal let invariants: [ArchitectureInvariant]
    private let nodeByID: [String: ArchitectureMapNode]
    private let nodeByHistoryKey: [String: ArchitectureMapNode]

    internal init(
        title: String = "",
        nodes: [ArchitectureMapNode],
        edges: [ArchitectureMapEdge],
        pages: [ArchitectureMapPage],
        boundaryGroups: [ArchitectureBoundaryGroup],
        clusters: [ArchitectureMapCluster],
        flows: [ArchitectureFlow],
        invariants: [ArchitectureInvariant]
    ) {
        self.title = title
        self.nodes = nodes
        self.edges = edges
        self.pages = pages
        self.boundaryGroups = boundaryGroups
        self.clusters = clusters
        self.flows = flows
        self.invariants = invariants
        var byID: [String: ArchitectureMapNode] = [:]
        var byKey: [String: ArchitectureMapNode] = [:]
        for node in nodes {
            if byID[node.id] == nil { byID[node.id] = node }
            if byKey[node.historyKey] == nil { byKey[node.historyKey] = node }
        }
        nodeByID = byID
        nodeByHistoryKey = byKey
    }

    internal static func decode(_ section: [String: AnyCodable], title: String = "") -> ArchitectureSystemMapDocument {
        ArchitectureSystemMapDocument(
            title: title,
            nodes: (section["nodes"]?.arrayValue ?? []).compactMap(ArchitectureMapNode.decode),
            edges: (section["edges"]?.arrayValue ?? []).compactMap(ArchitectureMapEdge.decode),
            pages: (section["pages"]?.arrayValue ?? []).compactMap(ArchitectureMapPage.decode),
            boundaryGroups: (section["boundary_groups"]?.arrayValue ?? []).compactMap(ArchitectureBoundaryGroup.decode),
            clusters: (section["clusters"]?.arrayValue ?? []).compactMap(ArchitectureMapCluster.decode),
            flows: (section["flows"]?.arrayValue ?? []).compactMap(ArchitectureFlow.decode),
            invariants: (section["invariants"]?.arrayValue ?? []).compactMap(ArchitectureInvariant.decode)
        )
    }

    /// The map of a whole document, or nil when it has no `interplay` section.
    /// The application hull takes the model's own title (the summary's title is
    /// the same value as the gateway derived it).
    internal static func decode(document: ArchitectureModelDocument) -> ArchitectureSystemMapDocument? {
        let title = document.model.dictionaryValue?["title"]?.stringValue ?? document.summary.title
        return document.section(.interplay).map { decode($0, title: title) }
    }

    /// What the application hull is called: the model's title, or a neutral word.
    internal var applicationLabel: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Application" : title
    }

    internal func node(id: String) -> ArchitectureMapNode? {
        nodeByID[id]
    }

    internal func node(historyKey: String) -> ArchitectureMapNode? {
        nodeByHistoryKey[historyKey]
    }

    internal var pageIDs: Set<String> {
        Set(pages.map(\.id))
    }

    /// Resolve a flow step's `from`/`to`: a history key first (the stable
    /// identity flows are written against), then an id, then a page pseudo-node.
    internal func resolve(stepEndpoint reference: String) -> ArchitectureFlowEndpoint {
        if let node = node(historyKey: reference) ?? node(id: reference) {
            return .node(node.id)
        }
        if reference.hasPrefix("page:") {
            let page = String(reference.dropFirst("page:".count))
            if pageIDs.contains(page) { return .page(page) }
        }
        return .unknown(reference)
    }

    /// The flows a node takes part in, in document order.
    internal func flows(involving nodeID: String) -> [ArchitectureFlow] {
        guard let node = nodeByID[nodeID] else { return [] }
        let named = Set(node.flowIDs)
        return flows.filter { flow in
            named.contains(flow.id) || flow.steps.contains { step in
                resolve(stepEndpoint: step.from) == .node(nodeID) || resolve(stepEndpoint: step.to) == .node(nodeID)
            }
        }
    }
}
