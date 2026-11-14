import Foundation
import Testing
@testable import Portal

@Suite("Graph stats — counts and structure behind the graph views")
internal struct GraphStatsTests {
    private func node(_ id: String, kind: String = "n") -> GraphStats.Node {
        GraphStats.Node(id: id, label: id.uppercased(), kind: kind)
    }

    private func edge(_ source: String, _ target: String, _ type: String = "link") -> GraphStats.Edge {
        GraphStats.Edge(source: source, target: target, type: type)
    }

    @Test("counts nodes, edges, kinds, components, isolated nodes and degrees")
    internal func coreCounts() {
        // a—b—c form one component, d—e another, f is isolated; one edge dangles.
        let stats = GraphStats.compute(
            nodes: [node("a", kind: "x"), node("b", kind: "x"), node("c", kind: "y"), node("d"), node("e"), node("f")],
            edges: [edge("a", "b"), edge("b", "c", "cites"), edge("d", "e"), edge("b", "zz")]
        )
        #expect(stats.nodeCount == 6)
        #expect(stats.edgeCount == 4)
        #expect(stats.danglingEdges == 1)
        #expect(stats.components == 3)
        #expect(stats.isolatedNodes == 1)
        #expect(stats.maxDegree == GraphStats.Degree(label: "B", degree: 2))
        #expect(abs(stats.averageDegree - 1.0) < 0.0001, "three connected edges over six nodes")
        #expect(stats.nodesByKind == [GraphStats.Row(label: "n", count: 3), GraphStats.Row(label: "x", count: 2), GraphStats.Row(label: "y", count: 1)])
        #expect(stats.edgesByType == [GraphStats.Row(label: "link", count: 3), GraphStats.Row(label: "cites", count: 1)])
    }

    @Test("an empty graph and a self-loop are handled without division or double counting")
    internal func edgeCases() {
        #expect(GraphStats.compute(nodes: [], edges: []) == .empty)
        let loop = GraphStats.compute(nodes: [node("a")], edges: [edge("a", "a")])
        #expect(loop.components == 1)
        #expect(loop.isolatedNodes == 0)
        #expect(loop.maxDegree?.degree == 1)
        // Duplicate node ids count once.
        let dup = GraphStats.compute(nodes: [node("a"), node("a")], edges: [])
        #expect(dup.nodeCount == 1)
        #expect(dup.isolatedNodes == 1)
    }

    @Test("rows sort by count then label, and the panel folds long breakdowns into 'other'")
    internal func rowsAndFolding() {
        let rows = GraphStats.rows(["b": 2, "a": 2, "c": 5, "d": 1])
        #expect(rows.map(\.label) == ["c", "a", "b", "d"])
        let many = (0..<9).map { GraphStats.Row(label: "k\($0)", count: 9 - $0) }
        let folded = GraphStats.folded(many)
        #expect(folded.count == GraphStats.breakdownLimit + 1)
        #expect(folded.last == GraphStats.Row(label: "other (3)", count: 3 + 2 + 1))
        #expect(GraphStats.folded(Array(many.prefix(3))).count == 3)
    }

    @Test("a wiki graph reports pages by type, links by relation and the wiki's extras")
    internal func wikiStats() {
        func page(_ id: String, type: String, tags: [String] = [], contested: Bool = false, links: [IntegrationLink] = []) -> WikiPage {
            WikiPage(id: id, title: id, type: type, tags: tags, path: "\(type)/\(id).md", created: nil, updated: nil,
                     confidence: nil, contested: contested, tagPath: [], integrationLinks: links)
        }
        let graph = WikiGraph(
            pages: [
                page("mlx", type: "entity", tags: ["ml"], links: [IntegrationLink(prefix: "github", identifier: "ml-explore/mlx")]),
                page("speed", type: "concept", tags: ["ml", "perf"], contested: true),
                page("orphan", type: "raw"),
            ],
            links: [WikiLink(source: "mlx", target: "speed", type: "wikilink"), WikiLink(source: "speed", target: "mlx", type: "compares")]
        )
        let stats = GraphStats.wiki(graph, pinnedCount: 1)
        #expect(stats.nodeCount == 3 && stats.edgeCount == 2)
        #expect(stats.nodesByKind.map(\.label) == ["concept", "entity", "raw"])
        #expect(stats.edgesByType == [GraphStats.Row(label: "compares", count: 1), GraphStats.Row(label: "wikilink", count: 1)])
        #expect(stats.components == 2 && stats.isolatedNodes == 1)
        let wiki = stats.extras.first { $0.title == "Wiki" }
        #expect(wiki != nil)
        let rows = Dictionary(uniqueKeysWithValues: (wiki?.rows ?? []).map { ($0.label, $0.count) })
        #expect(rows["Pinned pages"] == 1)
        #expect(rows["Contested pages"] == 1)
        #expect(rows["Untagged pages"] == 1)
        #expect(rows["Distinct tags"] == 2)
        #expect(rows["Integration links"] == 1)
    }

    @Test("a runtime graph reports jobs, services by provider and health, groups and revisions")
    internal func cronStats() {
        func service(_ id: String, health: String?) -> CronGraphNode {
            var node = CronGraphNode(id: id, kind: "service", type: "service", label: id, description: "",
                                     schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil)
            if let health {
                node.health = CronServiceHealth(status: health, probe: "http", target: "", checkedAt: "", latencyMilliseconds: 1, message: "")
            }
            return node
        }
        let job = CronGraphNode(id: "cron:digest", kind: "cron", type: "job", label: "digest", description: "",
                                schedule: "0 9 * * *", enabled: true, usesLLM: true, lastStatus: nil, deliver: nil)
        let disabled = CronGraphNode(id: "cron:old", kind: "cron", type: "job", label: "old", description: "",
                                     schedule: nil, enabled: false, usesLLM: false, lastStatus: nil, deliver: nil)
        let graph = CronGraph(nodes: [
            job, disabled,
            service("launchd:ai.hermes.gateway", health: "healthy"),
            service("docker:0123456789ab", health: "unhealthy"),
            service("proc_777", health: nil),
            service("arch:portal", health: "healthy"),
        ], edges: [
            CronGraphEdge(source: "cron:digest", target: "launchd:ai.hermes.gateway", type: "writes"),
            CronGraphEdge(source: "cron:digest", target: "docker:0123456789ab", type: "reads"),
        ])
        let stats = GraphStats.cron(graph, collapsedGroups: 2, revisionCount: 7)
        #expect(stats.nodeCount == 6 && stats.edgeCount == 2)
        #expect(stats.nodesByKind == [GraphStats.Row(label: "service", count: 4), GraphStats.Row(label: "cron", count: 2)])
        let runtime = Dictionary(uniqueKeysWithValues: (stats.extras.first { $0.title == "Runtime" }?.rows ?? []).map { ($0.label, $0.count) })
        #expect(runtime["Jobs"] == 2 && runtime["Enabled jobs"] == 1 && runtime["Jobs using an LLM"] == 1)
        #expect(runtime["Services"] == 4 && runtime["Healthy services"] == 2 && runtime["Unhealthy services"] == 1 && runtime["Unprobed services"] == 1)
        #expect(runtime["Collapsed groups"] == 2 && runtime["Revisions"] == 7)
        let providers = Dictionary(uniqueKeysWithValues: (stats.extras.first { $0.title == "Services by provider" }?.rows ?? []).map { ($0.label, $0.count) })
        #expect(providers == ["launchd": 1, "docker": 1, "process": 1, "architecture": 1])
        #expect(GraphStats.provider(ofServiceID: "0123456789ab") == "process")
    }

    @Test("the system map reports constructions by kind, edges by class, and the map's declarations")
    internal func systemMapStats() throws {
        let json = """
        {"nodes": [{"id": "store:s", "kind": "store", "label": "S"}, {"id": "caller:c", "kind": "caller", "label": "C"},
                   {"id": "external:x", "kind": "external", "label": "X"}],
         "edges": [{"source": "caller:c", "target": "store:s", "relation": "reads", "class": "usage"},
                   {"source": "store:s", "target": "external:x", "relation": "persists-to", "class": "boundary"}],
         "pages": [{"id": "chat", "label": "Chat"}], "boundary_groups": [{"id": "g", "label": "G", "members": ["external:x"]}],
         "clusters": [], "flows": [], "invariants": [{"id": "a", "kind": "k", "status": "holds", "why": ""}, {"id": "b", "kind": "k", "status": "violated", "why": ""}]}
        """
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        let document = ArchitectureSystemMapDocument.decode(try #require(value.dictionaryValue))
        let stats = GraphStats.systemMap(document, hullCount: 4)
        #expect(stats.nodeCount == 3 && stats.edgeCount == 2 && stats.components == 1)
        #expect(stats.edgesByType.map(\.count) == [1, 1])
        let map = Dictionary(uniqueKeysWithValues: (stats.extras.first { $0.title == "Map" }?.rows ?? []).map { ($0.label, $0.count) })
        #expect(map["Hulls"] == 4 && map["Pages"] == 1 && map["Boundary groups"] == 1)
        #expect(map["Invariants"] == 2 && map["Invariants holding"] == 1)
        let relations = stats.extras.first { $0.title == "Relations" }?.rows.map(\.label)
        #expect(relations == ["persists-to", "reads"])
    }

    @Test("view models recompute stats only when their graph changes")
    @MainActor
    internal func viewModelsMemoise() {
        let wiki = WikiGraphViewModel()
        #expect(wiki.graphStats == .empty)
        wiki.graph = WikiGraph(pages: [WikiPage(id: "p", title: "P", type: "entity", tags: [], path: "p.md", created: nil, updated: nil,
                                                confidence: nil, contested: false, tagPath: [], integrationLinks: [])], links: [])
        let first = wiki.graphStats
        #expect(first.nodeCount == 1)
        wiki.graph = wiki.graph
        #expect(wiki.graphStats == first, "an equal graph yields equal stats")
        let cron = CronGraphViewModel()
        #expect(cron.graphStats == .empty)
        cron.setGraphForTesting(CronGraph(nodes: [CronGraphNode(id: "cron:j", kind: "cron", type: "job", label: "j", description: "",
                                                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil)], edges: []))
        #expect(cron.graphStats.nodeCount == 1)
    }
}
