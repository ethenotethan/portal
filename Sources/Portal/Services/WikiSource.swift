import Foundation

// MARK: - WikiSource

/// The fetch surface the wiki views actually consume: a graph and page bodies.
///
/// The harness serves it over the `wiki.*` RPCs (below); `CodeGraphSource`
/// serves the same shape for a service's code graph, which is how the graph,
/// reader and sidebar render either without knowing which they're showing.
///
/// Deliberately does NOT include search — no view calls one; the wiki filters
/// the already-loaded graph client-side instead.
@MainActor
internal protocol WikiSource: AnyObject {
    func fetchGraph() async throws -> WikiGraph
    func fetchPage(path: String) async throws -> WikiPageContent
}

// MARK: - Harness conformance

/// GatewayClient already implements the underlying RPCs; adapt the shapes.
extension GatewayClient: WikiSource {
    internal func fetchGraph() async throws -> WikiGraph {
        try await wikiScan()
    }

    internal func fetchPage(path: String) async throws -> WikiPageContent {
        try await wikiPage(path: path)
    }
}
