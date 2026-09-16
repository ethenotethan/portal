import Foundation

// MARK: - CodeGraph → WikiGraph adapter

/// A `WikiSource` backed by a service's code knowledge graph, so the whole
/// `WikiGraphView` / canvas / physics stack renders it unchanged rather than a
/// second graph canvas being forked. It fetches `code.graph` for one service
/// and adapts the code-graph wire shape onto the wiki graph shape:
///
///   node → `WikiPage`  (title = symbol label, type = code kind, `path` = the
///           source-relative path so the renderer's folder-branch coloring
///           clusters nodes by directory for free)
///   edge → `WikiLink`  (relationship = the code relation: imports/calls/…)
///
/// `fetchPage` deep-links a node to its source file via `files.read`, using the
/// `root`/`rel` captured on the node — so tapping a symbol opens the code it was
/// extracted from.
@MainActor
internal final class CodeGraphSource: WikiSource, ObservableObject {
    private let client: GatewayClient
    private let service: String

    /// The last graph fetched, kept so `fetchPage` can resolve a WikiPage path
    /// back to the source file's `(root, rel)`. Also exposes `digest`/provenance
    /// for a host that wants to show the version anchor.
    internal private(set) var lastGraph: CodeGraph?

    /// path (as mapped onto `WikiPage.path`) → the file coordinates to read.
    private var fileIndex: [String: (root: String, rel: String)] = [:]

    internal init(client: GatewayClient, service: String) {
        self.client = client
        self.service = service
    }

    /// The `WikiPage.path` a node maps onto: the source-relative path when the
    /// node resolves to a file, else the node id (external/unresolved symbols).
    internal static func pagePath(for node: CodeGraphNode) -> String {
        node.rel ?? node.path ?? node.id
    }

    /// Pure adapter: a `CodeGraph` → the `WikiGraph` to render plus the
    /// path→`(root, rel)` index `fetchPage` needs. Split out from `fetchGraph`
    /// so the mapping is testable without a live gateway.
    internal static func mapToWikiGraph(
        _ graph: CodeGraph
    ) -> (graph: WikiGraph, fileIndex: [String: (root: String, rel: String)]) {
        var index: [String: (root: String, rel: String)] = [:]
        let pages: [WikiPage] = graph.nodes.map { node in
            let path = pagePath(for: node)
            if let root = node.root, let rel = node.rel {
                index[path] = (root, rel)
            }
            // Group by community then kind so the taxonomy tree (and the
            // folder-branch coloring's fallback) reflects the code's clusters.
            let group = node.community.map { "community/\($0)/\(node.kind)" } ?? "kind/\(node.kind)"
            return WikiPage(
                id: node.id,
                title: node.label,
                type: node.kind,
                tags: [],
                path: path,
                created: nil,
                updated: nil,
                confidence: nil,
                contested: false,
                tagPath: [group],
                integrationLinks: []
            )
        }
        let links: [WikiLink] = graph.edges.map { edge in
            WikiLink(source: edge.source, target: edge.target, type: edge.type)
        }
        return (WikiGraph(pages: pages, links: links), index)
    }

    internal func fetchGraph() async throws -> WikiGraph {
        let graph = try await client.codeGraph(service: service)
        lastGraph = graph
        let (wiki, index) = Self.mapToWikiGraph(graph)
        self.fileIndex = index
        return wiki
    }

    internal func fetchPage(path: String) async throws -> WikiPageContent {
        guard let coords = fileIndex[path] else {
            // External/unresolved symbol — no local file to open.
            return WikiPageContent(
                frontmatter: [:],
                body: "_No source file — this symbol is external to the service._",
                path: path
            )
        }
        let file = try await client.readFile(root: coords.root, path: coords.rel)
        return WikiPageContent(frontmatter: [:], body: file.content, path: path)
    }
}
