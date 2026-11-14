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

    // MARK: - Living artifacts

    private func livingArtifact(_ id: String, maintainers: [String] = [], updatedBy: String? = nil) -> CronGraphNode {
        CronGraphNode(
            id: "artifact:\(id)", kind: "artifact", type: "artifact", label: "Title \(id)", description: "",
            schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil,
            artifactID: id, artifactKind: "map", rev: 7, updatedAt: "2026-09-28T10:00:00Z",
            updatedBy: updatedBy, maintainers: maintainers
        )
    }

    @Test("a maintains edge is its own bucket, never a side effect")
    internal func maintainsIsFirstClass() {
        let graph = CronGraph(
            nodes: [node("job", kind: "cron"), livingArtifact("bkk-life", maintainers: ["cron:job"])],
            edges: [
                CronGraphEdge(source: "job", target: "artifact:bkk-life", type: "maintains"),
                // A maintains edge pointing AT the job is malformed and must not be counted anywhere.
                CronGraphEdge(source: "artifact:bkk-life", target: "job", type: "maintains"),
            ]
        )

        let flow = graph.dataflow(forCronID: "job")

        #expect(flow.maintains == [
            CronDataflowEndpoint(id: "artifact:bkk-life", label: "Title bkk-life", kind: "artifact", type: "artifact"),
        ])
        #expect(flow.sideEffects.isEmpty)
        #expect(flow.writes.isEmpty)
        #expect(flow.reads.isEmpty)
        #expect(!flow.isEmpty)
        #expect(graph.dataflow(forCronID: "other").isEmpty)
    }

    @Test("living-artifact fields decode from the wire and are absent-tolerant")
    internal func livingArtifactFieldsDecode() throws {
        let json = """
        {"nodes":[
          {"id":"artifact:bkk-life","kind":"artifact","type":"artifact","label":"Bangkok life",
           "artifact_id":"bkk-life","artifact_kind":"map","rev":12,"updated_at":"2026-09-28T09:30:00Z",
           "updated_by":"cron:abc123","maintainers":["cron:abc123","session:s1",""]},
          {"id":"wiki:x402","kind":"artifact","type":"wiki","label":"x402","artifact_kind":"","updated_by":""},
          {"id":"abc123","kind":"cron","label":"indexing/sweep"}
        ],"edges":[{"source":"abc123","target":"artifact:bkk-life","type":"maintains"}]}
        """
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        let graph = try CronGraph.decodeGatewayValue(value)
        let living = try #require(graph.nodes.first { $0.id == "artifact:bkk-life" })
        let declared = try #require(graph.nodes.first { $0.id == "wiki:x402" })

        #expect(living.artifactID == "bkk-life")
        #expect(living.artifactKind == "map")
        #expect(living.rev == 12)
        #expect(living.updatedAt == "2026-09-28T09:30:00Z")
        #expect(living.updatedAtDate != nil)
        #expect(living.updatedBy == "cron:abc123")
        #expect(living.maintainers == ["cron:abc123", "session:s1"])
        #expect(living.maintainerRefs == [.cron(jobID: "abc123"), .other(type: "session", value: "s1")])
        #expect(living.isLivingArtifact)

        // A declared ref without the living fields keeps its old shape: nothing
        // optional is invented, and an empty string on the wire is "not said".
        #expect(declared.artifactID == nil)
        #expect(declared.artifactKind == nil)
        #expect(declared.rev == nil)
        #expect(declared.updatedBy == nil)
        #expect(declared.maintainers.isEmpty)
        #expect(!declared.isLivingArtifact)
        #expect(graph.edges.first?.type == "maintains")
    }

    @Test("a revision snapshot written before the living fields existed still decodes, and new ones round-trip")
    internal func livingFieldsSnapshotCompatibility() throws {
        let legacy = """
        {"id":"artifact:x","kind":"artifact","type":"artifact","label":"x","description":"",
         "schedule":null,"enabled":true,"usesLLM":false,"lastStatus":null,"deliver":null}
        """
        let decodedLegacy = try JSONDecoder().decode(CronGraphNode.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.maintainers.isEmpty)
        #expect(decodedLegacy.artifactID == nil)
        #expect(!decodedLegacy.isLivingArtifact)

        let original = livingArtifact("bkk-life", maintainers: ["cron:job"], updatedBy: "agent")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CronGraphNode.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rev == 7)
        #expect(decoded.maintainers == ["cron:job"])
    }

    @Test("writer and maintainer refs resolve to job labels when the graph knows the job")
    internal func actorLabelsResolveThroughTheGraph() {
        let graph = CronGraph(
            nodes: [
                node("abc123", kind: "cron"),
                livingArtifact("bkk-life", maintainers: ["cron:abc123", "cron:gone", "session:s1", "agent"],
                               updatedBy: "cron:abc123"),
            ],
            edges: []
        )
        let artifact = graph.nodes[1]

        #expect(graph.actorLabel(for: "cron:abc123") == "label:abc123")
        // A maintainer naming a job the graph lacks stays visible as its id.
        #expect(graph.actorLabel(for: "cron:gone") == "gone")
        #expect(graph.actorLabel(for: "session:s1") == "session s1")
        #expect(graph.actorLabel(for: "agent") == "agent")
        #expect(graph.actorLabel(for: "   ") == "   ")
        #expect(graph.maintainerLabels(for: artifact) == ["label:abc123", "gone", "session s1", "agent"])
        // Only a cron node satisfies a cron ref — a resource sharing the id does not.
        let resourceOnly = CronGraph(nodes: [node("abc123", kind: "source", type: "https")], edges: [])
        #expect(resourceOnly.actorLabel(for: "cron:abc123") == "abc123")
    }
}
