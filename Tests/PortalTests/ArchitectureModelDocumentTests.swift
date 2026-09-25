import Testing
import Foundation
@testable import Portal

@Suite("Architecture model document — architecture.describe wire shape")
internal struct ArchitectureModelDocumentTests {
    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private let full = """
    {
      "service": {"id": "arch:portal", "label": "Portal", "description": "Native client.", "source": "local",
                  "root": "/Users/me/portal", "repository": null, "ref": null,
                  "model_path": "architecture/model/model.json", "check_configured": true},
      "revision": "62911e4f1c2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b",
      "source": "local",
      "stored_at": "2026-09-24T09:00:00+00:00",
      "summary": {"schema_version": "1.0.0", "title": "Portal Architecture", "components": 31, "files": 401,
                  "lines": 108000, "nodes": 240, "edges": 900, "flows": 42,
                  "invariants": {"total": 12, "holds": 11, "violated": ["pool-guarded"]},
                  "stores": 21, "externals": 13, "gates": 14, "ratchets": 7, "workflows": 7},
      "check": {"status": "failed", "exit_code": 1, "output": "stale", "reason": "", "checked_at": "2026-09-24T09:01:00+00:00",
                "revision": "62911e4f1c2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b", "duration_s": 42.5, "command": ["python3", "x.py"]},
      "model": {"schema_version": "1.0.0", "title": "Portal Architecture", "components": [{"id": "a"}], "path": "x/</script>"}
    }
    """

    @Test("decodes the service, revision, summary, check and the model as JSON")
    internal func decodesFullDocument() throws {
        let document = try ArchitectureModelDocument.decodeGatewayValue(try decode(full))
        #expect(document.service.id == "arch:portal")
        #expect(document.service.label == "Portal")
        #expect(document.service.isLocal)
        #expect(document.service.checkConfigured)
        #expect(document.service.origin == "/Users/me/portal")
        #expect(document.revision.hasPrefix("62911e4f"))
        #expect(document.shortRevision == "62911e4f1")
        #expect(document.storedAt == "2026-09-24T09:00:00+00:00")
        #expect(document.summary.components == 31)
        #expect(document.summary.invariantsTotal == 12)
        #expect(document.summary.invariantsHolding == 11)
        #expect(document.summary.violated == ["pool-guarded"])
        #expect(!document.summary.allInvariantsHold)
        #expect(document.summary.gates == 14)
        let check = try #require(document.check)
        #expect(check.status == "failed")
        #expect(check.exitCode == 1)
        #expect(check.ran)
        #expect(!check.passed)
        #expect(check.durationSeconds == 42.5)
        // The model round-trips as sorted, slash-preserving JSON the renderer can consume.
        #expect(document.modelJSON.hasPrefix("{\"components\":[{\"id\":\"a\"}]"))
        #expect(document.modelJSON.contains("\"path\":\"x/</script>\""))
        let reparsed = try JSONSerialization.jsonObject(with: Data(document.modelJSON.utf8)) as? [String: Any]
        #expect(reparsed?["schema_version"] as? String == "1.0.0")
    }

    @Test("carries the contract the gateway validated against and the sections the model has")
    internal func contractAndSections() throws {
        let document = try ArchitectureModelDocument.decodeGatewayValue(try decode(full))
        // No contract in the envelope: an older gateway; the document is treated as unvalidated 1.x.
        #expect(document.contract == .unknown)
        #expect(document.contract.major == 0)
        #expect(document.sections == [.components])
        #expect(document.has(.components))
        #expect(!document.has(.ci))
        #expect(document.missingRequiredSections == [.interplay, .extraction, .ci, .inventory])
        #expect(document.section(.components) == nil, "components is an array, not a dictionary section")
        let withContract = full.replacingOccurrences(
            of: "\"revision\":",
            with: "\"contract\": {\"name\": \"hermes.architecture\", \"version\": \"1.0\"}, \"revision\":"
        ).replacingOccurrences(
            of: "\"components\": [{\"id\": \"a\"}],",
            with: "\"components\": [{\"id\": \"a\"}], \"interplay\": {\"nodes\": []}, \"extraction\": {\"files\": []}, "
                + "\"ci\": {\"jobs\": []}, \"inventory\": {\"files\": 1}, \"stores\": {\"items\": []},"
        )
        let conforming = try ArchitectureModelDocument.decodeGatewayValue(try decode(withContract))
        #expect(conforming.contract.name == "hermes.architecture")
        #expect(conforming.contract.version == "1.0")
        #expect(conforming.contract.major == 1, "major parsed from the version when the envelope omits it")
        #expect(conforming.contract.minor == 0)
        #expect(conforming.contract.schemaDigest == nil)
        #expect(conforming.contract.isKnown)
        #expect(conforming.contract.caption == "hermes.architecture v1.0")
        #expect(conforming.tooltip.contains("contract hermes.architecture v1.0"))
        #expect(document.tooltip.contains("contract unvalidated"))
        let explicit = ArchitectureContractRef.decodeGatewayValue(try decode(
            "{\"name\": \"hermes.architecture\", \"version\": \"1.2\", \"major\": 1, \"minor\": 2, \"schema_digest\": \"abc\"}"
        ))
        #expect(explicit.major == 1)
        #expect(explicit.minor == 2)
        #expect(explicit.schemaDigest == "abc")
        let nameless = ArchitectureContractRef.decodeGatewayValue(try decode("{\"version\": \"1.0\"}"))
        #expect(nameless == .unknown, "a contract needs a name")
        #expect(conforming.sections == [.components, .interplay, .extraction, .ci, .inventory, .stores])
        #expect(conforming.missingRequiredSections.isEmpty)
        #expect(conforming.section(.ci)?["jobs"]?.arrayValue?.isEmpty == true)
        #expect(conforming.model.dictionaryValue?["title"]?.stringValue == "Portal Architecture")
    }

    @Test("an architecture request carries the service's code graph and turns it into a code-graph request")
    internal func requestCarriesCodeGraph() {
        let plain = ArchitectureRequest(service: "arch:portal", label: "Portal", revision: "abc")
        #expect(plain.codeGraph == nil)
        #expect(plain.codeGraphRequest == nil)
        #expect(plain.id == "arch:portal")
        let withGraph = ArchitectureRequest(
            service: "launchd:demo", label: "Demo", revision: "abc",
            codeGraph: CronServiceCodeGraphRef(ref: "launchd:demo", digest: "d1")
        )
        let request = withGraph.codeGraphRequest
        #expect(request?.service == "launchd:demo")
        #expect(request?.label == "Demo")
        #expect(request?.digest == "d1")
    }

    @Test("a GitHub service names its repository and ref as the origin; a digest revision stays whole")
    internal func githubOrigin() throws {
        let json = """
        {"service": {"id": "arch:remote", "source": "github", "repository": "o/r", "ref": "main", "check_configured": false},
         "revision": "sha256:abcdef0123456789", "source": "github",
         "model": {"schema_version": "1.0.0"}}
        """
        let document = try ArchitectureModelDocument.decodeGatewayValue(try decode(json))
        #expect(!document.service.isLocal)
        #expect(document.service.origin == "o/r @ main")
        #expect(document.service.label == "arch:remote", "label falls back to the id")
        #expect(document.service.modelPath == "architecture/model/model.json")
        #expect(document.shortRevision == "sha256:abcdef0123456789")
        #expect(document.summary == .empty)
        #expect(document.check == nil)
        #expect(document.storedAt == nil)
    }

    @Test("a result without a service or a model is rejected")
    internal func rejectsIncompleteDocuments() throws {
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureModelDocument.decodeGatewayValue(try decode("{\"revision\": \"x\", \"model\": {}}"))
        }
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureModelDocument.decodeGatewayValue(try decode("{\"service\": {\"id\": \"arch:a\"}, \"model\": 3}"))
        }
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureModelDocument.decodeGatewayValue(try decode("[]"))
        }
    }

    @Test("check results decode every status and tolerate missing fields")
    internal func checkResults() throws {
        let passed = ArchitectureCheckResult.decodeGatewayValue(try decode("{\"status\": \"passed\", \"exit_code\": 0}"))
        #expect(passed?.passed == true)
        #expect(passed?.ran == true)
        #expect(passed?.output.isEmpty == true)
        let unavailable = ArchitectureCheckResult.decodeGatewayValue(try decode("{\"status\": \"unavailable\", \"reason\": \"no check\"}"))
        #expect(unavailable?.ran == false)
        #expect(unavailable?.reason == "no check")
        #expect(unavailable?.exitCode == nil)
        #expect(ArchitectureCheckResult.decodeGatewayValue(try decode("{\"exit_code\": 0}")) == nil)
        #expect(ArchitectureServiceRef.decodeGatewayValue(try decode("{\"label\": \"no id\"}")) == nil)
    }

    @Test("tooltips carry every decoded field")
    internal func tooltips() throws {
        let document = try ArchitectureModelDocument.decodeGatewayValue(try decode(full))
        let expectedTooltip = "Native client.\nPortal Architecture · schema 1.0.0\n"
            + "architecture/model/model.json at 62911e4f1c2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b (local)\nstored 2026-09-24T09:00:00+00:00\n"
            + "contract unvalidated (gateway predates the contract)"
        #expect(document.tooltip == expectedTooltip)
        let expectedDetail = "31 components · 401 files · 108000 lines · 240 nodes · 900 edges · 42 flows · "
            + "11/12 invariants (violated: pool-guarded) · 21 stores · 13 externals · 14 gates · 7 ratchets · 7 workflows"
        #expect(document.summary.detailLine == expectedDetail)
        let check = try #require(document.check)
        #expect(check.detail == "Last check: failed\nat 2026-09-24T09:01:00+00:00\nrevision 62911e4f1c2d3a4b5c6d7e8f9a0b1c2d3e4f5a6b\nexit 1\nstale")
        let bare = ArchitectureCheckResult(status: "unavailable", exitCode: nil, output: "", reason: "no check", checkedAt: "", revision: "", durationSeconds: 0)
        #expect(bare.detail == "Last check: unavailable\nno check")
        let empty = ArchitectureModelDocument(
            service: ArchitectureServiceRef(id: "arch:x", label: "X", description: "", source: "github", root: nil, repository: "o/r", ref: "main",
                                            modelPath: "m.json", checkConfigured: false),
            revision: "v1", source: "github", storedAt: nil, summary: .empty, check: nil, contract: .unknown,
            model: .dictionary([:]), modelJSON: "{}"
        )
        #expect(empty.tooltip == "architecture model · schema ?\nm.json at v1 (github)\ncontract unvalidated (gateway predates the contract)")
        #expect(ArchitectureModelSummary.empty.detailLine.hasPrefix("0 components · 0 files"))
    }

    @Test("a request is identified by its service")
    internal func requestIdentity() {
        let request = ArchitectureRequest(service: "arch:portal", label: "Portal", revision: "abc")
        #expect(request.id == "arch:portal")
    }
}
