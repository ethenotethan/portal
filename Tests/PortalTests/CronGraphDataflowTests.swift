import Foundation
import Testing
@testable import Portal

@Suite("Cron job dataflow projection")
internal struct CronGraphDataflowTests {
    private func node(_ id: String, kind: String, type: String? = nil) -> CronGraphNode {
        CronGraphNode(
            id: id,
            kind: kind,
            type: type ?? kind,
            label: "label:\(id)",
            description: "",
            schedule: nil,
            enabled: true,
            usesLLM: false,
            lastStatus: nil,
            deliver: nil
        )
    }

    @Test("relationship-class edges never become cron side effects")
    internal func relationshipEdgesAreNotSideEffects() {
        let graph = CronGraph(
            nodes: [node("job", kind: "cron"), node("runtime:docker", kind: "object", type: "runtime")],
            edges: [CronGraphEdge(source: "job", target: "runtime:docker",
                                  type: "runs_in", edgeClass: "relationship")]
        )

        #expect(graph.dataflow(forCronID: "job").isEmpty)
    }

    @Test("gateway relationship class survives wire decoding")
    internal func relationshipClassDecodesFromGateway() throws {
        let json = #"{"nodes":[],"edges":[{"source":"nomad:gateway","target":"runtime:docker","type":"runs_in","class":"relationship"}]}"#
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        let edge = try #require(CronGraph.decodeGatewayValue(value).edges.first)

        #expect(edge.edgeClass == "relationship")
    }

    @Test("edge identity includes both endpoints and the relationship type")
    internal func edgeIdentityIsRelationshipSpecific() {
        let edge = CronGraphEdge(source: "job", target: "wiki:output", type: "writes")

        #expect(edge.id == "job->wiki:output:writes")
        #expect(edge.id != CronGraphEdge(source: "job", target: "wiki:output", type: "feeds").id)
        #expect(edge.id != CronGraphEdge(source: "other", target: "wiki:output", type: "writes").id)
        #expect(edge.id != CronGraphEdge(source: "job", target: "other", type: "writes").id)
    }

    @Test("projection classifies every relationship and preserves endpoint metadata")
    internal func classifiesRelationships() {
        let graph = CronGraph(
            nodes: [
                node("job", kind: "cron"),
                node("upstream", kind: "cron"),
                node("downstream", kind: "cron"),
                node("https:input", kind: "source", type: "https"),
                node("wiki:output", kind: "artifact", type: "wiki"),
                node("notify:team", kind: "sink", type: "generic"),
            ],
            edges: [
                CronGraphEdge(source: "https:input", target: "job", type: "reads"),
                CronGraphEdge(source: "job", target: "wiki:output", type: "writes"),
                CronGraphEdge(source: "upstream", target: "job", type: "feeds"),
                CronGraphEdge(source: "job", target: "downstream", type: "feeds"),
                CronGraphEdge(source: "job", target: "notify:team", type: "telegram"),
            ]
        )

        let flow = graph.dataflow(forCronID: "job")

        #expect(flow.reads == [
            CronDataflowEndpoint(id: "https:input", label: "label:https:input", kind: "source", type: "https"),
        ])
        #expect(flow.writes.map(\.id) == ["wiki:output"])
        #expect(flow.fedBy.map(\.id) == ["upstream"])
        #expect(flow.feeds.map(\.id) == ["downstream"])
        #expect(flow.sideEffects == [
            CronDataflowEndpoint(id: "notify:team", label: "label:notify:team", kind: "sink", type: "telegram"),
        ])
        #expect(!flow.isEmpty)
    }

    @Test("projection skips unrelated and dangling edges and deduplicates each bucket")
    internal func skipsInvalidAndDeduplicates() {
        let graph = CronGraph(
            nodes: [
                node("job", kind: "cron"),
                node("other", kind: "cron"),
                node("wiki:shared", kind: "artifact", type: "wiki"),
            ],
            edges: [
                CronGraphEdge(source: "job", target: "wiki:shared", type: "writes"),
                CronGraphEdge(source: "job", target: "wiki:shared", type: "writes"),
                CronGraphEdge(source: "other", target: "wiki:shared", type: "writes"),
                CronGraphEdge(source: "missing", target: "job", type: "reads"),
                CronGraphEdge(source: "job", target: "missing", type: "slack"),
            ]
        )

        let flow = graph.dataflow(forCronID: "job")

        #expect(flow.writes.map(\.id) == ["wiki:shared"])
        #expect(flow.reads.isEmpty)
        #expect(flow.feeds.isEmpty)
        #expect(flow.fedBy.isEmpty)
        #expect(flow.sideEffects.isEmpty)
        #expect(graph.dataflow(forCronID: "").isEmpty)
        #expect(CronGraph.empty.isEmpty)
    }
}
