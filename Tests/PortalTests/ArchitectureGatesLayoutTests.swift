import Testing
import Foundation
@testable import Portal

@Suite("Architecture gates layout — the circuit's geometry")
internal struct ArchitectureGatesLayoutTests {
    private func real() throws -> (ArchitectureGatesDocument, ArchitectureGatesLayout) {
        let gates = try #require(ArchitectureGatesDocument.decode(try ArchitectureGatesFixtures.realModelCI()))
        return (gates, ArchitectureGatesLayout.layout(gates))
    }

    @Test("depth is the longest needs chain; unknown needs and cycles contribute nothing")
    internal func depth() {
        func job(_ id: String, needs: [String]) -> ArchitectureGateJob {
            ArchitectureGateJob(id: id, key: id, name: id, workflow: "w", family: "f", role: .gate, needs: needs, runsOn: "", condition: nil,
                                steps: [], stepCount: 0, scripts: [], artifactsIn: [], artifactsOut: [], pins: [], evidence: nil)
        }
        let a = job("a", needs: [])
        let b = job("b", needs: ["a"])
        let c = job("c", needs: ["b", "a"])
        let d = job("d", needs: ["ghost"])
        let e = job("e", needs: ["f"])
        let f = job("f", needs: ["e"])
        let jobs = Dictionary(uniqueKeysWithValues: [a, b, c, d, e, f].map { ($0.id, $0) })
        #expect(ArchitectureGatesLayout.depth(of: a, in: jobs) == 0)
        #expect(ArchitectureGatesLayout.depth(of: b, in: jobs) == 1)
        #expect(ArchitectureGatesLayout.depth(of: c, in: jobs) == 2)
        #expect(ArchitectureGatesLayout.depth(of: d, in: jobs) == 1, "a need that is not a job still counts one hop")
        #expect(ArchitectureGatesLayout.depth(of: e, in: jobs) == 2, "a cycle terminates")
        #expect(ArchitectureGatesLayout.familyRank("behavior") == 0)
        #expect(ArchitectureGatesLayout.familyRank("maintenance") == 5)
        #expect(ArchitectureGatesLayout.familyRank("unknown") == ArchitectureGatesLayout.familyOrder.count)
    }

    @Test("the real pipeline: every gate job placed in its workflow lane by depth, the merge past the deepest gate, the rest downstream")
    internal func realPipeline() throws {
        let (gates, layout) = try real()
        let metrics = ArchitectureGatesLayout.Metrics()
        for job in gates.jobs {
            #expect(layout.node(job.id) != nil, "\(job.id) is drawn")
        }
        let merge = try #require(layout.node("merge:main"))
        #expect(merge.kind == .merge)
        #expect(Set(merge.inputs) == Set(gates.merge?.inputs ?? []))
        let trigger = try #require(layout.node("trigger:pull_request"))
        #expect(trigger.kind == .trigger)
        #expect(trigger.frame.minX == metrics.margin)
        // Gate jobs sit in a lane named for their workflow, in a column matching their depth.
        let jobsByID = gates.jobsByID
        for job in gates.jobs where job.role.guardsTheMerge {
            let node = try #require(layout.node(job.id))
            let lane = try #require(layout.lanes.first { $0.id == job.workflow })
            #expect(lane.kind == .gates)
            #expect(lane.frame.contains(node.frame), "\(job.id) inside its lane")
            let column = (node.frame.minX - (metrics.margin + metrics.triggerWidth + metrics.columnGap)) / (metrics.nodeWidth + metrics.columnGap)
            #expect(Int(column.rounded()) == ArchitectureGatesLayout.depth(of: job, in: jobsByID), "\(job.id) column")
            #expect(node.frame.maxX < merge.frame.minX, "gates precede the merge")
        }
        // Coverage needs measure: one column to its right, wired by an artifact hand-off.
        let measure = try #require(layout.node("ratchet/measure"))
        let coverage = try #require(layout.node("ratchet/coverage"))
        #expect(coverage.frame.minX > measure.frame.maxX)
        let artifact = try #require(layout.wires.first { $0.source == "ratchet/measure" && $0.target == "ratchet/coverage" })
        #expect(artifact.kind == .artifact)
        #expect(artifact.label == "metric-snapshots")
        #expect(artifact.labelAt != nil)
        #expect(artifact.points.first?.x == measure.frame.maxX)
        #expect(artifact.points.last?.x == coverage.frame.minX)
        // Post-merge jobs to the right of the merge inside the after-merge lane; manual jobs in their own band beneath.
        for job in gates.jobs where job.role.runsAfterMerge {
            let node = try #require(layout.node(job.id))
            #expect(node.frame.minX > merge.frame.maxX, "\(job.id) after the merge")
            let lane = try #require(layout.lanes.first { $0.id == "after-merge" })
            #expect(lane.frame.contains(node.frame))
        }
        let manualLane = try #require(layout.lanes.first { $0.id == "manual" })
        #expect(manualLane.kind == .manual)
        for job in gates.jobs where job.role == .manual {
            let node = try #require(layout.node(job.id))
            #expect(manualLane.frame.contains(node.frame))
            #expect(node.frame.minY > merge.frame.maxY, "manual band is beneath the gate band")
        }
        #expect(layout.node("trigger:workflow_dispatch")?.kind == .trigger)
        // Every gate wire lands on the merge's pin for that job; wires whose ends are not drawn are dropped.
        let gateWires = layout.wires.filter { $0.kind == .gates }
        #expect(gateWires.count == merge.inputs.count)
        for wire in gateWires {
            #expect(wire.points.last?.x == merge.frame.minX)
            #expect(wire.points.count == 6)
        }
        let drawnWires = gates.wires.filter { layout.node($0.source) != nil && layout.node($0.target) != nil }
        #expect(layout.wires.count == drawnWires.count)
        #expect(layout.wires.count <= gates.wires.count, "a wire whose end is not drawn is skipped, never invented")
        #expect(layout.size.width > merge.frame.maxX)
        #expect(layout.size.height >= manualLane.frame.maxY)
        #expect(layout.nodes.map(\.id).count == Set(layout.nodes.map(\.id)).count, "ids unique")
    }

    @Test("the layout is deterministic and lanes are ordered by family then name")
    internal func deterministic() throws {
        let (gates, layout) = try real()
        #expect(ArchitectureGatesLayout.layout(gates) == layout)
        let ranks = layout.lanes.filter { $0.kind == .gates }.map { ArchitectureGatesLayout.familyRank($0.family) }
        #expect(ranks == ranks.sorted())
        let ys = layout.lanes.filter { $0.kind == .gates }.map(\.frame.minY)
        #expect(ys == ys.sorted())
    }

    @Test("selection helpers walk wires both ways")
    internal func selection() throws {
        let (_, layout) = try real()
        let touching = layout.wires(touching: "ratchet/measure")
        #expect(touching.contains { $0.target == "ratchet/coverage" })
        #expect(touching.contains { $0.target == "merge:main" })
        #expect(layout.upstream(of: "ratchet/coverage").contains("ratchet/measure"))
        #expect(layout.upstream(of: "ratchet/coverage").contains("trigger:pull_request"))
        #expect(layout.downstream(of: "ratchet/measure").contains("merge:main"))
        #expect(layout.downstream(of: "ratchet/measure").contains("ratchet/coverage"))
        #expect(!layout.downstream(of: "merge:main").contains("trigger:pull_request"))
        let connected = layout.connected(to: "ratchet/measure")
        #expect(connected.contains("ratchet/measure"))
        #expect(connected.isSuperset(of: ["ratchet/coverage", "merge:main", "trigger:pull_request"]))
        #expect(layout.wires(touching: "nope").isEmpty)
        #expect(layout.node("nope") == nil)
    }

    @Test("a local-only service: its check is the only gate, the merge is its snapshot, an unknown role is drawn nowhere")
    internal func localOnly() throws {
        let gates = try #require(ArchitectureGatesDocument.decode(try ArchitectureGatesFixtures.localOnlyCI()))
        let layout = ArchitectureGatesLayout.layout(gates)
        let check = try #require(layout.node("local/check"))
        #expect(check.role == .local)
        let lane = try #require(layout.lanes.first { $0.id == "local" })
        #expect(lane.frame.contains(check.frame))
        let merge = try #require(layout.node("merge:snapshot"))
        #expect(merge.inputs == ["local/check"])
        #expect(merge.frame.height == 88, "the minimum AND-gate height with one pin")
        let trigger = try #require(layout.node("trigger:check"))
        #expect(trigger.label == "check → main")
        #expect(layout.node("local/ship") == nil, "a custom role is neither a gate nor post-merge nor manual")
        #expect(layout.lanes.map(\.id) == ["local"], "no after-merge or manual band")
        #expect(layout.node("trigger:workflow_dispatch") == nil)
        let gate = try #require(layout.wires.first { $0.kind == .gates })
        #expect(gate.points.last?.y == merge.frame.minY + 13, "one pin sits at the top offset")
        #expect(layout.wires.count == 1, "the hand-off to an undrawn job is dropped")
        #expect(layout.upstream(of: "merge:snapshot") == ["local/check"])
    }

    @Test("an empty document lays out nothing but the input signal")
    internal func emptyDocument() {
        let gates = ArchitectureGatesDocument(
            workflows: [], jobs: [], wires: [], triggers: [], merge: nil, ratchets: [], staticChecks: [], architectural: .empty,
            families: [:], limitations: [], summary: ArchitectureGatesSummary.decode(nil)
        )
        let layout = ArchitectureGatesLayout.layout(gates)
        #expect(layout.nodes.map(\.id) == ["trigger:pull_request"])
        #expect(layout.lanes.isEmpty && layout.wires.isEmpty)
        #expect(layout.size.width > 0 && layout.size.height > 0)
        #expect(ArchitectureGatesLayout.empty.nodes.isEmpty)
        #expect(ArchitectureGatesLayout.empty.size == .zero)
    }

    @Test("release wires and needs wires between post-merge jobs are orthogonal and reach both ends")
    internal func postMergeWires() throws {
        let (gates, layout) = try real()
        for wire in layout.wires where wire.kind == .release || wire.kind == .needs || wire.kind == .trigger {
            let source = try #require(layout.node(wire.source))
            let target = try #require(layout.node(wire.target))
            #expect(wire.points.first == CGPoint(x: source.frame.maxX, y: source.frame.midY))
            #expect(wire.points.last == CGPoint(x: target.frame.minX, y: target.frame.midY))
            #expect(wire.points.count == 4)
            for (a, b) in zip(wire.points, wire.points.dropFirst()) {
                #expect(a.x == b.x || a.y == b.y, "orthogonal segments")
            }
            #expect(wire.labelAt == nil)
        }
        #expect(gates.wires.contains { $0.kind == .release } == layout.wires.contains { $0.kind == .release })
    }
}
