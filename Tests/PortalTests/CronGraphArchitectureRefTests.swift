import Testing
import Foundation
@testable import Portal

@Suite("Cron graph — architecture annotation on service nodes")
internal struct CronGraphArchitectureRefTests {
    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private let graph = """
    {"nodes": [
      {"id": "arch:portal", "kind": "service", "type": "service", "label": "Portal", "description": "d",
       "source_files": [{"path": "/p/scripts/build.py", "declared": "scripts/build.py", "role": "declared", "root": "arch-portal", "rel": "scripts/build.py", "exists": true}],
       "architecture": {"ref": "arch:portal", "source": "local", "revision": "62911e4", "model": "architecture/model/model.json",
                        "snapshots": 3, "check": {"status": "passed", "checked_at": "t"}}},
      {"id": "proc_1", "kind": "service", "type": "service", "label": "Dash", "description": "d"},
      {"id": "job", "kind": "cron", "type": "cron", "label": "Job", "description": "", "enabled": true}
    ], "edges": []}
    """

    @Test("a manifest service decodes its annotation and source files; other services carry none")
    internal func decodesAnnotation() throws {
        let decoded = try CronGraph.decodeGatewayValue(try decode(graph))
        let portal = try #require(decoded.nodes.first { $0.id == "arch:portal" })
        let ref = try #require(portal.architecture)
        #expect(ref.ref == "arch:portal")
        #expect(ref.source == "local")
        #expect(ref.revision == "62911e4")
        #expect(ref.checkStatus == "passed")
        #expect(ref.snapshots == 3)
        #expect(portal.sourceFiles.count == 1)
        #expect(portal.sourceFiles.first?.isOpenable == true)
        let dash = try #require(decoded.nodes.first { $0.id == "proc_1" })
        #expect(dash.architecture == nil)
        #expect(try #require(decoded.nodes.first { $0.id == "job" }).architecture == nil)
    }

    @Test("an annotation without a ref is ignored; missing fields default")
    internal func tolerantDecoding() throws {
        #expect(CronServiceArchitectureRef.decodeGatewayValue(try decode("{\"source\": \"local\"}")) == nil)
        let minimal = try #require(CronServiceArchitectureRef.decodeGatewayValue(try decode("{\"ref\": \"arch:x\"}")))
        #expect(minimal.source == "local")
        #expect(minimal.revision.isEmpty)
        #expect(minimal.checkStatus == nil)
        #expect(minimal.snapshots == 0)
        #expect(minimal.conformance == .unknown, "a gateway that predates the contract says nothing about conformance")
        #expect(minimal.contractVersion == nil)
    }

    @Test("a contract-aware gateway reports conformance and the contract version on the annotation")
    internal func contractFields() throws {
        let annotated = try #require(CronServiceArchitectureRef.decodeGatewayValue(try decode(
            "{\"ref\": \"arch:x\", \"conforming\": false, \"contract\": {\"name\": \"hermes.architecture\", \"version\": \"1.0\"}}"
        )))
        #expect(annotated.conformance == .nonConforming)
        #expect(annotated.contractVersion == "1.0")
        let data = try JSONEncoder().encode(annotated)
        let restored = try JSONDecoder().decode(CronServiceArchitectureRef.self, from: data)
        #expect(restored.conformance == .nonConforming)
        #expect(restored.contractVersion == "1.0")
        let good = try #require(CronServiceArchitectureRef.decodeGatewayValue(try decode("{\"ref\": \"arch:y\", \"conforming\": true}")))
        #expect(good.conformance == .conforming)
        #expect(good.contractVersion == nil)
        // A snapshot written before the field existed decodes as unknown.
        let legacy = try JSONDecoder().decode(
            CronServiceArchitectureRef.self,
            from: Data("{\"ref\": \"arch:z\", \"source\": \"local\", \"revision\": \"r\", \"snapshots\": 1}".utf8)
        )
        #expect(legacy.conformance == .unknown)
    }

    @Test("the annotation survives the local snapshot round trip and is absent from older snapshots")
    internal func codableRoundTrip() throws {
        let decoded = try CronGraph.decodeGatewayValue(try decode(graph))
        let data = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode(CronGraph.self, from: data)
        #expect(restored.nodes.first { $0.id == "arch:portal" }?.architecture?.revision == "62911e4")
        let legacy = """
        {"nodes": [{"id": "s", "kind": "service", "type": "service", "label": "S", "description": "", "enabled": true, "usesLLM": false}], "edges": []}
        """
        let old = try JSONDecoder().decode(CronGraph.self, from: Data(legacy.utf8))
        #expect(old.nodes.first?.architecture == nil)
    }

    @Test("the annotation stays outside the configuration digest")
    internal func outsideDigest() throws {
        let with = try CronGraph.decodeGatewayValue(try decode(graph))
        var object = try #require(JSONSerialization.jsonObject(with: Data(graph.utf8)) as? [String: Any])
        var nodes = try #require(object["nodes"] as? [[String: Any]])
        nodes[0]["architecture"] = nil
        object["nodes"] = nodes
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let without = try CronGraph.decodeGatewayValue(try JSONDecoder().decode(AnyCodable.self, from: stripped))
        #expect(without.nodes.first { $0.id == "arch:portal" }?.architecture == nil)
        #expect(CronGraphDigest.configurationForm(with) == CronGraphDigest.configurationForm(without))
    }
}
