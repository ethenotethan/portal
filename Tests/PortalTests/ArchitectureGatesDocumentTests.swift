import Testing
import Foundation
@testable import Portal

/// Shared fixtures: the real compiled model and a hand-written local-only service.
internal enum ArchitectureGatesFixtures {
    internal static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    internal static func realModelCI() throws -> [String: AnyCodable] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("architecture/model/model.json"))
        let model = try JSONDecoder().decode(AnyCodable.self, from: data)
        return try #require(model.dictionaryValue?["ci"]?.dictionaryValue)
    }

    /// A service with no GitHub Actions: one local workflow whose single job is
    /// the service's own check, the merge gate being the snapshot that check guards.
    internal static let localOnly = """
    {
      "workflows": [{"id": "local", "label": "Local", "name": "Local checks", "family": "posture", "jobs": ["local/check"], "events": ["local"],
                     "question": "Does the compiled model match the tree?"}],
      "jobs": [{"id": "local/check", "key": "check", "name": "architecture --check", "workflow": "local", "family": "posture", "role": "local",
                "needs": [], "runs_on": "gateway", "condition": null, "step_count": 1,
                "steps": [{"name": "Compile and compare", "command": "python3 build_architecture.py --check", "line": 1}],
                "scripts": ["build_architecture.py"], "artifacts_in": [], "artifacts_out": [], "pins": ["PY=3.14"],
                "evidence": {"path": "manifest.json", "line": 4}},
               {"id": "local/ship", "key": "ship", "name": "ship", "workflow": "local", "family": "weird-family", "role": "beta-role",
                "needs": ["local/check"], "runs_on": "", "steps": [], "step_count": 0, "scripts": [], "artifacts_in": [], "artifacts_out": []}],
      "edges": [{"source": "local/check", "target": "merge:snapshot", "kind": "gates"},
                {"source": "local/check", "target": "local/ship", "kind": "handoff", "label": "model"}],
      "triggers": [{"id": "trigger:check", "event": "check", "workflows": ["local"]}],
      "merge": {"id": "merge:snapshot", "label": "Snapshot accepted", "inputs": ["local/check"]},
      "ratchets": [{"id": "size", "title": "Model size", "job": "local/check", "measures": "bytes", "floor": "never grows past 16 MiB",
                    "patch": null, "current": {"kind": "count", "total": 1200, "counts": {}}},
                   {"id": "flags", "title": "Flags", "job": "local/check", "measures": "counters", "floor": "none",
                    "current": {"kind": "counters", "counts": {"a": 1, "b": 2}}},
                   {"id": "lint", "title": "Lint", "job": "local/check", "measures": "rules", "floor": "no growth",
                    "current": {"kind": "count", "total": 42, "counts": {"x": 40, "y": 2}}},
                   {"id": "odd", "title": "Odd", "job": "local/check", "measures": "?", "floor": "?", "current": {"kind": "mystery"}}],
      "static_checks": [{"name": "Freshness", "command": "python3 build_architecture.py --check", "job": "local/check", "scripts": [],
                         "evidence": {"path": "manifest.json", "line": 9}}],
      "architectural": {"lint_rules": [{"id": "no_print", "message": "no print", "severity": "error", "baselined": 3, "excluded_count": 0,
                                        "evidence": {"path": ".lint.yml", "line": 2}}],
                        "tests": [{"title": "one", "evidence": {"path": "t.py", "line": 1}}],
                        "invariants": [{"id": "inv", "kind": "k", "status": "violated", "why": "because"}],
                        "runs_in": ["local/check"], "lint_config": ".lint.yml", "tests_path": "t.py"},
      "families": {"posture": {"question": "Did a metric get worse?"}, "flat": "A plain string question"},
      "limitations": ["Nothing is proven about branch protection."],
      "summary": {"workflows": 1, "jobs": 2, "gates": 1, "ratchets": 4, "static_checks": 1, "lint_rules": 1, "architecture_tests": 1, "invariants": 1}
    }
    """

    internal static func localOnlyCI() throws -> [String: AnyCodable] {
        try #require(try JSONDecoder().decode(AnyCodable.self, from: Data(localOnly.utf8)).dictionaryValue)
    }
}

@Suite("Architecture gates document — the `ci` section typed")
internal struct ArchitectureGatesDocumentTests {
    @Test("decodes the real compiled model: every job, wire, ratchet and check")
    internal func decodesRealModel() throws {
        let section = try ArchitectureGatesFixtures.realModelCI()
        let gates = try #require(ArchitectureGatesDocument.decode(section))
        #expect(gates.jobs.count == section["jobs"]?.arrayValue?.count)
        #expect(gates.workflows.count == section["workflows"]?.arrayValue?.count)
        #expect(gates.wires.count == section["edges"]?.arrayValue?.count)
        #expect(gates.ratchets.count == section["ratchets"]?.arrayValue?.count)
        #expect(gates.staticChecks.count == section["static_checks"]?.arrayValue?.count)
        #expect(gates.triggers.map(\.id).contains("trigger:pull_request"))
        let merge = try #require(gates.merge)
        #expect(merge.id == "merge:main")
        #expect(merge.inputs.count == gates.summary.gates)
        #expect(gates.jobs.filter { $0.role == .gate }.count == gates.summary.gates)
        #expect(gates.summary.jobs == gates.jobs.count)
        #expect(gates.summary.architecturalChecks == gates.architectural.count)
        #expect(gates.families["posture"] == "Did a tracked metric get worse?")
        #expect(gates.limitations.count == 3)
        // Every wire endpoint is a job, a trigger or the merge gate.
        let known = Set(gates.jobs.map(\.id) + gates.triggers.map(\.id) + [merge.id])
        for wire in gates.wires {
            #expect(known.contains(wire.source), "\(wire.source)")
            #expect(known.contains(wire.target), "\(wire.target)")
        }
        // Jobs carry their evidence and steps.
        let build = try #require(gates.job("build/build"))
        #expect(build.evidence?.display == ".github/workflows/build.yml:14")
        #expect(build.steps.count == build.stepCount)
        #expect(build.steps.contains { $0.uses == "actions/checkout@v4" })
        #expect(build.steps.contains { $0.command?.hasPrefix("brew install") == true })
        #expect(build.artifactsOut == ["ios-ui-smoke-artifacts"])
        #expect(build.condition == nil)
        // Ratchet current values read like the web renderer's.
        let coverage = try #require(gates.ratchets.first { $0.id == "coverage" })
        #expect(coverage.currentKind == "coverage")
        #expect(coverage.currentSummary.hasSuffix(")"))
        #expect(coverage.currentSummary.contains("%"))
        #expect(coverage.breakdown.map(\.key) == ["Models", "Services", "Utilities", "ViewModels"])
        #expect(coverage.patch?.contains("80%") == true)
        let lint = try #require(gates.architectural.lintRules.first)
        #expect(!lint.id.isEmpty)
        #expect(lint.evidence?.path == ".swiftlint.yml")
        let allHold = gates.architectural.invariants.allSatisfy { $0.holds }
        #expect(allHold)
        #expect(gates.workflowsByID["build"]?.jobs.contains("build/build") == true)
        #expect(gates.jobsByID["build/build"] == build)
    }

    @Test("a local-only service decodes, with unknown roles, wire kinds and families kept as custom values")
    internal func decodesLocalOnly() throws {
        let gates = try #require(ArchitectureGatesDocument.decode(try ArchitectureGatesFixtures.localOnlyCI()))
        let check = try #require(gates.job("local/check"))
        #expect(check.role == .local)
        #expect(check.role.guardsTheMerge)
        #expect(!check.role.runsAfterMerge)
        #expect(check.pins.map(\.display) == ["PY=3.14"])
        #expect(check.evidence?.display == "manifest.json:4")
        let ship = try #require(gates.job("local/ship"))
        #expect(ship.role == .custom("beta-role"))
        #expect(ship.role.rawValue == "beta-role")
        #expect(!ship.role.guardsTheMerge && !ship.role.runsAfterMerge)
        #expect(ship.condition == nil)
        #expect(ship.needs == ["local/check"])
        let handoff = try #require(gates.wires.first { $0.target == "local/ship" })
        #expect(handoff.kind == .custom("handoff"))
        #expect(handoff.kind.rawValue == "handoff")
        #expect(handoff.label == "model")
        #expect(gates.wires.first?.kind == .gates)
        #expect(gates.merge?.inputs == ["local/check"])
        #expect(gates.families == ["posture": "Did a metric get worse?", "flat": "A plain string question"])
        #expect(gates.architectural.invariants.first?.holds == false)
        #expect(gates.architectural.lintRules.first?.baselined == 3)
        #expect(gates.architectural.tests.first?.id == "one")
        #expect(gates.staticChecks.first?.id == "local/check#Freshness")
        #expect(gates.summary.architecturalChecks == 3)
        #expect(gates.triggers.first?.event == "check")
    }

    @Test("ratchet baselines summarise per kind: count, count in categories, counters, unknown")
    internal func ratchetSummaries() throws {
        let gates = try #require(ArchitectureGatesDocument.decode(try ArchitectureGatesFixtures.localOnlyCI()))
        let byID = Dictionary(uniqueKeysWithValues: gates.ratchets.map { ($0.id, $0) })
        #expect(byID["size"]?.currentSummary == "1,200")
        #expect(byID["size"]?.patch == nil)
        #expect(byID["size"]?.breakdown.isEmpty == true)
        #expect(byID["flags"]?.currentSummary == "2 counters")
        #expect(byID["flags"]?.breakdown.map(\.value) == ["2", "1"], "largest first")
        #expect(byID["lint"]?.currentSummary == "42 in 2 rules")
        #expect(byID["lint"]?.breakdown.map(\.key) == ["x", "y"])
        #expect(byID["odd"]?.currentSummary == "—")
        #expect(byID["odd"]?.breakdown.isEmpty == true)
        let coverage = ArchitectureRatchet(
            id: "coverage", title: "c", job: "j", measures: "", floor: "", patch: nil, sourcePath: nil,
            current: ["kind": .string("coverage"), "percent": .double(47.019), "covered": .int(12967), "count": .int(27577),
                      "layers": .dictionary(["Models": .dictionary(["percent": .double(72.29)])])]
        )
        #expect(coverage.currentSummary == "47.02% (12,967 / 27,577)")
        #expect(coverage.breakdown.map(\.value) == ["72.3%"])
        #expect(coverage == coverage)
        #expect(coverage.hashValue == coverage.hashValue)
        #expect(coverage != byID["odd"])
    }

    @Test("roles and wire kinds round-trip through their raw values")
    internal func rolesAndKinds() {
        for raw in ["gate", "post-merge", "manual", "disabled", "local", "other"] {
            #expect(ArchitectureGateRole(rawValue: raw).rawValue == raw)
        }
        #expect(ArchitectureGateRole(rawValue: "post-merge") == .postMerge)
        #expect(ArchitectureGateRole.postMerge.runsAfterMerge)
        #expect(ArchitectureGateRole.disabled.runsAfterMerge)
        #expect(ArchitectureGateRole.gate.guardsTheMerge)
        #expect(!ArchitectureGateRole.manual.guardsTheMerge)
        for raw in ["needs", "artifact", "gates", "trigger", "release", "zap"] {
            #expect(ArchitectureGateWireKind(rawValue: raw).rawValue == raw)
        }
    }

    @Test("absent or job-less sections decode to nothing; tolerant field defaults")
    internal func tolerantDecoding() throws {
        #expect(ArchitectureGatesDocument.decode(nil) == nil)
        #expect(ArchitectureGatesDocument.decode(["jobs": .array([])]) == nil)
        #expect(ArchitectureGatesDocument.decode(["jobs": .array([.dictionary(["id": .string("")])])]) == nil)
        let minimal = try #require(ArchitectureGatesDocument.decode(["jobs": .array([.dictionary(["id": .string("w/j")])])]))
        let job = try #require(minimal.job("w/j"))
        #expect(job.name == "w/j")
        #expect(job.key == "w/j")
        #expect(job.role == .gate)
        #expect(job.needs.isEmpty && job.steps.isEmpty && job.pins.isEmpty)
        #expect(job.evidence == nil)
        #expect(minimal.merge == nil)
        #expect(minimal.architectural == .empty)
        #expect(minimal.summary.gates == 0)
        #expect(minimal.workflows.isEmpty && minimal.wires.isEmpty && minimal.triggers.isEmpty)
        // Steps and pins with sparse fields.
        #expect(ArchitectureGateStep.decode(.dictionary(["uses": .string("a/b@v1")]))?.name == "a/b@v1")
        #expect(ArchitectureGateStep.decode(.dictionary(["command": .string("make")]))?.name == "make")
        #expect(ArchitectureGateStep.decode(.dictionary([:]))?.name == "step")
        #expect(ArchitectureGateStep.decode(.string("x")) == nil)
        #expect(ArchitectureGatePin.decode(.dictionary(["name": .string("N"), "value": .string("1")]))?.display == "N=1")
        #expect(ArchitectureGatePin.decode(.string("JUSTNAME"))?.display == "JUSTNAME=")
        #expect(ArchitectureGatePin.decode(.int(3)) == nil)
        #expect(ArchitectureSourceLine.decode(.dictionary(["path": .string("p")]))?.display == "p:0")
        #expect(ArchitectureSourceLine.decode(nil) == nil)
        #expect(ArchitectureGateWire.decode(.dictionary(["source": .string("a")])) == nil)
        #expect(ArchitectureGateWorkflow.decode(.dictionary(["id": .string("w")]))?.name == "w")
        #expect(ArchitectureGateTrigger.decode(.dictionary(["id": .string("t")]))?.event == "t")
        #expect(ArchitectureMergeGate.decode(.dictionary(["id": .string("m")]))?.label == "Merge")
        #expect(ArchitectureRatchet.decode(.dictionary(["id": .string("r")]))?.title == "r")
        #expect(ArchitectureStaticCheck.decode(.dictionary(["name": .string("s")]))?.id == "#s")
        #expect(ArchitectureLintRule.decode(.dictionary(["id": .string("l")]))?.severity == "warning")
        #expect(ArchitectureCheckedInvariant.decode(.dictionary(["id": .string("i")]))?.status == "unchecked")
        #expect(ArchitectureTestCase.decode(.string("x")) == nil)
    }
}
