import Foundation
import SwiftUI

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

// MARK: - Dedicated code graph surface

/// Loading state for the code-graph sheet. The graph renderer can share the
/// force-layout model with the wiki, but the product surface must not inherit
/// wiki chrome, copy, empty states, or navigation.
@MainActor
internal final class CodeGraphSurfaceModel: ObservableObject {
    internal enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed
    }

    @Published internal private(set) var phase: Phase = .idle
    @Published internal private(set) var codeGraph: CodeGraph?
    @Published internal private(set) var renderGraph: WikiGraph = .empty
    @Published internal private(set) var errorMessage: String?

    private let fetch: @MainActor () async throws -> CodeGraph

    internal init(fetch: @escaping @MainActor () async throws -> CodeGraph) {
        self.fetch = fetch
    }

    internal convenience init(client: GatewayClient, service: String) {
        self.init { try await client.codeGraph(service: service) }
    }

    internal func load() async {
        phase = .loading
        errorMessage = nil
        do {
            let graph = try await fetch()
            codeGraph = graph
            renderGraph = CodeGraphSource.mapToWikiGraph(graph).graph
            phase = graph.isEmpty ? .empty : .loaded
        } catch {
            codeGraph = nil
            renderGraph = .empty
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }
}

/// Purpose-built code topology surface. It deliberately uses only the shared
/// force-directed canvas, not `WikiGraphView`: users see code nodes/edges and
/// code-specific loading/empty/error states rather than a nested "Wiki" app.
@MainActor
internal struct CodeGraphSurfaceView: View {
    private let request: CodeGraphRequest
    @StateObject private var model: CodeGraphSurfaceModel
    @Environment(\.dismiss) private var dismiss

    internal init(request: CodeGraphRequest, client: GatewayClient) {
        self.request = request
        _model = StateObject(
            wrappedValue: CodeGraphSurfaceModel(client: client, service: request.service)
        )
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            content
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
        .background(Theme.background)
        .task(id: request.digest) { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .portalButton(prominent: true, size: .small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var summary: String {
        guard let graph = model.codeGraph else { return "Code graph" }
        return "\(graph.nodes.count) nodes · \(graph.edges.count) edges"
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            stateMessage(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Building code graph",
                detail: "Extracting modules, symbols, and relationships…",
                showsProgress: true
            )
        case .loaded:
            InteractiveGraphView(graph: model.renderGraph)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            stateMessage(
                icon: "curlybraces",
                title: "No code symbols found",
                detail: "The service has no graphable source files in an allowed source root."
            )
        case .failed:
            VStack(spacing: 14) {
                stateMessage(
                    icon: "exclamationmark.triangle",
                    title: "Code graph unavailable",
                    detail: model.errorMessage ?? "The gateway could not build this service's code graph."
                )
                Button("Try Again") { Task { await model.load() } }
                    .portalButton(prominent: false, size: .small)
            }
        }
    }

    private func stateMessage(
        icon: String,
        title: String,
        detail: String,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
