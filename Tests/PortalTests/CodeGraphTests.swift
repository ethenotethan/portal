import Foundation
import SwiftUI
import Testing
@testable import Portal

/// Coverage for the per-service code knowledge graph on the client: the
/// `code.graph` wire decode, the `CodeGraph → WikiGraph` adapter used to render
/// it on the shared wiki canvas, the new `code_graph`/`code_control` fields on
/// the cron service node, and the additive code-kind color/radius cases (a
/// renderer regression guard: wiki types must be unchanged). Pure model + view
/// model logic — no gateway, no view.
@Suite("Code graph")
@MainActor
internal struct CodeGraphTests {

    private func decodeCode(_ json: String) throws -> CodeGraph {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return try CodeGraph.decodeGatewayValue(value)
    }

    private func decodeCron(_ json: String) throws -> CronGraph {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return try CronGraph.decodeGatewayValue(value)
    }

    // MARK: - code.graph wire decode

    @Test("code.graph decodes nodes, typed edges, provenance and communities")
    internal func decodesCodeGraph() throws {
        let json = """
        {
          "service": "ingestor",
          "digest": "abc123",
          "code_control": {"repository": "github:o/r", "revision": "deadbeef",
                           "pull_request": {"number": 7}},
          "nodes": [
            {"id": "app/server.py", "kind": "module", "type": "module",
             "label": "server.py", "path": "app/server.py", "root": "repo",
             "rel": "app/server.py", "line": 1, "community": "1"},
            {"id": "app/server.py::handle", "kind": "func", "type": "func",
             "label": "handle()", "path": "app/server.py", "root": "repo",
             "rel": "app/server.py", "line": 10, "community": "1"},
            {"id": "json", "kind": "external", "type": "external", "label": "json"}
          ],
          "edges": [
            {"source": "app/server.py", "target": "app/server.py::handle",
             "type": "contains", "class": "structure", "confidence": "EXTRACTED"},
            {"source": "app/server.py::handle", "target": "json",
             "type": "imports", "class": "flow", "confidence": "EXTRACTED"}
          ],
          "communities": {"1": ["app/server.py", "app/server.py::handle"]}
        }
        """
        let graph = try decodeCode(json)

        #expect(graph.service == "ingestor")
        #expect(graph.digest == "abc123")
        #expect(graph.codeControl?.repository == "github:o/r")
        #expect(graph.codeControl?.revision == "deadbeef")
        #expect(graph.codeControl?.pullRequest == 7)
        #expect(graph.nodes.count == 3)

        let module = try #require(graph.nodes.first { $0.id == "app/server.py" })
        #expect(module.kind == "module")
        #expect(module.root == "repo")
        #expect(module.rel == "app/server.py")
        #expect(module.line == 1)
        #expect(module.community == "1")

        let external = try #require(graph.nodes.first { $0.id == "json" })
        #expect(external.kind == "external")
        #expect(external.root == nil)
        #expect(external.line == nil)

        // Edge class carried through; the flow subgraph is the import edge.
        let flow = graph.edges.filter(\.isFlow)
        #expect(flow.count == 1)
        #expect(flow.first?.type == "imports")
        #expect(graph.communities["1"]?.count == 2)
    }

    @Test("code.graph tolerates missing optional fields and defaults edge class")
    internal func decodesSparseCodeGraph() throws {
        let json = """
        {"nodes":[{"id":"x"}],
         "edges":[{"source":"x","target":"y"}]}
        """
        let graph = try decodeCode(json)
        let node = try #require(graph.nodes.first)
        #expect(node.kind == "symbol")     // default
        #expect(node.type == "symbol")     // falls back to kind
        #expect(node.label == "x")         // falls back to id
        #expect(node.community == nil)
        let edge = try #require(graph.edges.first)
        #expect(edge.type == "references") // default
        #expect(edge.edgeClass == "reference")
        #expect(!edge.isFlow)
    }

    @Test("code.graph missing nodes/edges arrays throws")
    internal func rejectsMalformedCodeGraph() {
        #expect(throws: (any Error).self) {
            _ = try decodeCode("{\"service\":\"x\"}")
        }
    }

    // MARK: - CronGraph service node: code_graph + code_control

    @Test("a service cron node decodes code_graph{ref,digest} and code_control")
    internal func decodesServiceCodeGraphRef() throws {
        let json = """
        {"nodes":[
          {"id":"svc-1","kind":"service","label":"Ingestor",
           "code_graph":{"ref":"svc-1","digest":"d1"},
           "code_control":{"repository":"github:o/r","revision":"cafe"}},
          {"id":"job-1","kind":"cron","label":"nightly"}
        ],"edges":[]}
        """
        let graph = try decodeCron(json)
        let service = try #require(graph.nodes.first { $0.id == "svc-1" })
        #expect(service.codeGraph?.ref == "svc-1")
        #expect(service.codeGraph?.digest == "d1")
        #expect(service.codeControl?.repository == "github:o/r")
        #expect(service.codeControl?.revision == "cafe")

        // A plain cron node has neither — the button stays hidden.
        let job = try #require(graph.nodes.first { $0.id == "job-1" })
        #expect(job.codeGraph == nil)
        #expect(job.codeControl == nil)
    }

    // MARK: - CodeGraph → WikiGraph adapter

    @Test("mapToWikiGraph maps nodes/edges and builds a file index for resolvable nodes")
    internal func mapsToWikiGraph() throws {
        let json = """
        {"nodes":[
          {"id":"m","kind":"module","label":"server.py","path":"app/server.py",
           "root":"repo","rel":"app/server.py","community":"2"},
          {"id":"ext","kind":"external","label":"json"}
        ],"edges":[
          {"source":"m","target":"ext","type":"imports","class":"flow"}
        ]}
        """
        let (wiki, index) = CodeGraphSource.mapToWikiGraph(try decodeCode(json))

        let modulePage = try #require(wiki.pages.first { $0.id == "m" })
        #expect(modulePage.title == "server.py")   // label → title
        #expect(modulePage.type == "module")        // kind → type
        #expect(modulePage.path == "app/server.py") // rel → path (folder coloring)
        #expect(modulePage.tagPath == ["community/2/module"])

        // External node has no file coordinates → falls back to id, not indexed.
        let extPage = try #require(wiki.pages.first { $0.id == "ext" })
        #expect(extPage.path == "ext")
        #expect(index["ext"] == nil)

        // Resolvable module is indexed by its page path for fetchPage deep-link.
        let coords = try #require(index["app/server.py"])
        #expect(coords.root == "repo")
        #expect(coords.rel == "app/server.py")

        // Edge relationship carried onto the wiki link.
        let link = try #require(wiki.links.first)
        #expect(link.source == "m")
        #expect(link.target == "ext")
        #expect(link.type == "imports")
    }

    @Test("mapToWikiGraph groups nodes without a community under kind/<kind>")
    internal func groupsUnclusteredNodes() throws {
        let json = """
        {"nodes":[{"id":"f","kind":"func","label":"go()"}],"edges":[]}
        """
        let (wiki, _) = CodeGraphSource.mapToWikiGraph(try decodeCode(json))
        #expect(wiki.pages.first?.tagPath == ["kind/func"])
    }

    @Test("an unresolved code node opens an explanatory page without an RPC")
    internal func opensUnresolvedNodeWithoutReadingAFile() async throws {
        let source = CodeGraphSource(client: GatewayClient(), service: "svc")

        let page = try await source.fetchPage(path: "external-symbol")

        #expect(page.path == "external-symbol")
        #expect(page.body.contains("external to the service"))
    }

    @Test("code graph convenience identities and empty state remain stable")
    internal func convenienceIdentitiesAndEmptyState() throws {
        let edge = CodeGraphEdge(source: "a", target: "b", type: "calls", edgeClass: "flow")
        #expect(edge.id == "a->b:calls")

        let request = CodeGraphRequest(service: "svc", label: "Service")
        #expect(request.id == "svc")
        #expect(request.digest.isEmpty)
        #expect(CodeGraph.empty.isEmpty)
    }

    // MARK: - Color / radius regression guard

    @Test("code kinds get distinct colors; wiki types are unchanged")
    internal func codeKindColorsAreDistinctAndAdditive() {
        let vm = WikiGraphViewModel()
        let codeKinds = ["module", "class", "func", "symbol", "external"]
        let colors = codeKinds.map { vm.color(for: $0) }
        // Each code kind resolves to a distinct color (none fell to the default).
        #expect(Set(colors).count == codeKinds.count)
        #expect(vm.color(for: "module") != vm.color(for: "unknown-type"))
        // Wiki types keep their existing colors (renderer regression guard).
        #expect(vm.color(for: "entity") == Color(hex: "7c7cff"))
        #expect(vm.color(for: "glossary") == Color(hex: "5ad4e6"))
        // Modules read as hubs; externals smaller than the default.
        #expect(vm.nodeRadius(for: "module") == 8)
        #expect(vm.nodeRadius(for: "external") == 4)
        #expect(vm.nodeRadius(for: "entity") == 7)
    }
}
