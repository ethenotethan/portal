import Foundation

// MARK: - Code knowledge graph (per service)

/// The code knowledge graph for one `service` node, as built by the gateway's
/// `code.graph` RPC (harness `cron/code_graph.py`): module/class/function nodes
/// and typed import/call/structure edges extracted from the service's declared
/// `source_files`, clustered into communities.
///
/// It rides the SAME `{source, target, type, class}` typed-edge shape as
/// `CronGraph`, so `CodeGraphSource` can adapt it onto `WikiGraph` and reuse the
/// wiki graph renderer wholesale rather than forking a second canvas.

/// One node — a module, class, function, plain symbol, or an external/imported
/// name the extractor could not resolve to a file in the service's sources.
internal struct CodeGraphNode: Identifiable, Hashable, Codable {
    internal let id: String
    /// `module` | `class` | `func` | `symbol` | `external` — drives node color.
    internal let kind: String
    /// Fine-grained type; today it mirrors `kind`, kept distinct for parity with
    /// the cron graph wire and to leave room for a richer taxonomy later.
    internal let type: String
    internal let label: String
    /// Root-relative path of the file this node lives in, for deep-linking to the
    /// source. `nil` for external/unresolved nodes (they belong to no local file).
    internal let path: String?
    /// The browse root (`repo` | `hermes`) the file opens under, for `files.read`.
    internal let root: String?
    /// The path relative to `root` — the argument `files.read` wants. Usually
    /// equal to `path`; kept separate to mirror the wire and the cron source-file
    /// model, where they can diverge.
    internal let rel: String?
    /// 1-based line of the declaration, when the extractor reported one.
    internal let line: Int?
    /// The Louvain community id (as a string) this node was clustered into, or
    /// `nil` when clustering was unavailable. Drives community grouping.
    internal let community: String?
}

/// A typed directed edge. `edgeClass` buckets `type` into the three families the
/// builder maps graphify's relation vocabulary onto: `flow` (imports/calls — the
/// system-flow subgraph), `structure` (nesting/inheritance), `reference` (else).
internal struct CodeGraphEdge: Identifiable, Hashable, Codable {
    internal var id: String { "\(source)->\(target):\(type)" }
    internal let source: String
    internal let target: String
    internal let type: String
    internal let edgeClass: String
    internal let confidence: String?

    internal init(source: String, target: String, type: String, edgeClass: String, confidence: String? = nil) {
        self.source = source
        self.target = target
        self.type = type
        self.edgeClass = edgeClass
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case source, target, type, confidence
        case edgeClass = "class"
    }

    /// Whether this edge is part of the system-flow subgraph (an import or call).
    internal var isFlow: Bool { edgeClass == "flow" }
}

/// The version anchor for the graph: the verified commit/PR the service's code
/// was resolved at, echoed back so a surface can show "this graph is of
/// owner/name @ revision". `nil` when the service has no verified code-control.
internal struct CodeGraphProvenance: Hashable, Codable {
    internal let repository: String?
    internal let revision: String?
    internal let pullRequest: Int?

    internal static func decodeGatewayValue(_ value: AnyCodable) -> CodeGraphProvenance? {
        guard let d = value.dictionaryValue else { return nil }
        let repository = d["repository"]?.stringValue
        let revision = d["revision"]?.stringValue
        // pull_request is a nested object on the wire ({number, ...}); take just
        // the number, tolerating either a bare int or the object form.
        let pull = d["pull_request"]?.dictionaryValue?["number"]?.intValue
            ?? d["pull_request"]?.intValue
        if repository == nil, revision == nil, pull == nil { return nil }
        return CodeGraphProvenance(repository: repository, revision: revision, pullRequest: pull)
    }
}

/// A request to open a service's code knowledge graph, raised on one surface
/// (the inline detail dock) and fulfilled on another (the full-screen graph).
/// `id` is the service ref so `.sheet(item:)` / `.task(id:)` re-fire when the
/// selection changes; `digest` is the change-token to refetch on.
internal struct CodeGraphRequest: Identifiable, Hashable {
    internal let service: String
    internal let label: String
    internal let digest: String

    internal var id: String { service }

    internal init(service: String, label: String, digest: String = "") {
        self.service = service
        self.label = label
        self.digest = digest
    }
}

/// The full response of `code.graph` for one service.
internal struct CodeGraph: Codable, Equatable {
    internal let service: String
    /// Content digest of the service's source files — the change-token. A refetch
    /// is warranted exactly when this differs from the stamp on the cron node.
    internal let digest: String
    internal let codeControl: CodeGraphProvenance?
    internal let nodes: [CodeGraphNode]
    internal let edges: [CodeGraphEdge]
    /// Community id → member node ids. Parallel to the per-node `community`.
    internal let communities: [String: [String]]

    internal static let empty = CodeGraph(
        service: "", digest: "", codeControl: nil, nodes: [], edges: [], communities: [:]
    )

    internal var isEmpty: Bool { nodes.isEmpty }

    /// Decode the gateway's wire value. Like `CronGraph.decodeGatewayValue`, this
    /// reads the wire's own key names and tolerates omissions rather than routing
    /// through `Codable` (which exists here only for local use/fixtures).
    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> CodeGraph {
        guard let dict = value.dictionaryValue,
              let nodesArray = dict["nodes"]?.arrayValue,
              let edgesArray = dict["edges"]?.arrayValue else {
            throw GatewayError.invalidResponse("code.graph missing nodes/edges arrays")
        }

        let nodes: [CodeGraphNode] = nodesArray.compactMap { item in
            guard let d = item.dictionaryValue,
                  let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
            let kind = d["kind"]?.stringValue ?? "symbol"
            return CodeGraphNode(
                id: id,
                kind: kind,
                type: d["type"]?.stringValue ?? kind,
                label: d["label"]?.stringValue ?? id,
                path: d["path"]?.stringValue,
                root: d["root"]?.stringValue,
                rel: d["rel"]?.stringValue,
                line: d["line"]?.intValue,
                community: d["community"]?.stringValue
            )
        }

        let edges: [CodeGraphEdge] = edgesArray.compactMap { item in
            guard let d = item.dictionaryValue,
                  let source = d["source"]?.stringValue,
                  let target = d["target"]?.stringValue else { return nil }
            return CodeGraphEdge(
                source: source,
                target: target,
                type: d["type"]?.stringValue ?? "references",
                edgeClass: d["class"]?.stringValue ?? "reference",
                confidence: d["confidence"]?.stringValue
            )
        }

        var communities: [String: [String]] = [:]
        for (cid, members) in dict["communities"]?.dictionaryValue ?? [:] {
            communities[cid] = (members.arrayValue ?? []).compactMap(\.stringValue)
        }

        return CodeGraph(
            service: dict["service"]?.stringValue ?? "",
            digest: dict["digest"]?.stringValue ?? "",
            codeControl: dict["code_control"].flatMap(CodeGraphProvenance.decodeGatewayValue),
            nodes: nodes,
            edges: edges,
            communities: communities
        )
    }
}
