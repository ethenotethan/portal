import CoreGraphics
import Foundation
import Testing
@testable import Portal

@MainActor
@Suite("Cron graph view model — selection & zoom")
internal struct CronGraphViewModelTests {

    private func seededVM() -> CronGraphViewModel {
        let vm = CronGraphViewModel()
        vm.simNodes = [
            CronGraphViewModel.SimNode(id: "job-a", position: .zero, kind: "cron", type: "cron", label: "A"),
            CronGraphViewModel.SimNode(id: "wiki-raw", position: .zero, kind: "artifact", type: "snapshot", label: "wiki raw"),
            CronGraphViewModel.SimNode(id: "job-b", position: .zero, kind: "cron", type: "cron", label: "B"),
        ]
        return vm
    }

    // MARK: - selectNode(withID:)

    @Test("selectNode(withID:) selects the node carrying that id")
    internal func selectByIDSelectsMatchingNode() {
        let vm = seededVM()
        vm.selectNode(withID: "wiki-raw")
        #expect(vm.selectedNodeIndex == 1)
    }

    @Test("selectNode(withID:) with an unknown id is a no-op")
    internal func selectByUnknownIDIsNoOp() {
        let vm = seededVM()
        vm.selectedNodeIndex = 0
        vm.selectNode(withID: "does-not-exist")
        #expect(vm.selectedNodeIndex == 0)

        vm.selectedNodeIndex = nil
        vm.selectNode(withID: "still-nope")
        #expect(vm.selectedNodeIndex == nil)
    }

    // MARK: - glyph(forKind:)

    @Test("each node kind maps to its own silhouette; unknown kinds fall back to a circle")
    internal func glyphMapsKindToShape() {
        let vm = CronGraphViewModel()
        #expect(vm.glyph(forKind: "cron") == .circle)
        #expect(vm.glyph(forKind: "source") == .triangle)
        #expect(vm.glyph(forKind: "artifact") == .cylinder)
        #expect(vm.glyph(forKind: "sink") == .diamond)
        // Every real kind is distinct, so shape alone delineates them.
        let shapes: [CronGraphViewModel.NodeGlyph] = ["cron", "source", "artifact", "sink"].map { vm.glyph(forKind: $0) }
        #expect(Set(shapes).count == 4)
        // An unrecognized kind still draws something rather than vanishing.
        #expect(vm.glyph(forKind: "mystery") == .circle)
    }

    // MARK: - effectiveGraph / collapse

    private func groupedVM() -> CronGraphViewModel {
        let vm = CronGraphViewModel()
        vm.setGraphForTesting(CronGraph(
            nodes: [
                CronGraphNode(id: "job", kind: "cron", type: "cron", label: "job",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
                CronGraphNode(id: "wiki:a", kind: "artifact", type: "wiki", label: "a",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
                CronGraphNode(id: "wiki:b", kind: "artifact", type: "wiki", label: "b",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
            ],
            edges: [
                CronGraphEdge(source: "job", target: "wiki:a", type: "writes"),
                CronGraphEdge(source: "job", target: "wiki:b", type: "writes"),
            ]
        ))
        return vm
    }

    @Test("collapsing a scheme folds its members into one super-node and reroutes edges")
    internal func collapseFoldsMembersAndReroutesEdges() {
        let vm = groupedVM()
        #expect(vm.effectiveGraph().nodes.count == 3) // uncollapsed: raw graph

        vm.toggleGroupCollapsed("wiki")
        let effective = vm.effectiveGraph()
        // job + one wiki super-node = 2 nodes; the two members are gone.
        #expect(effective.nodes.count == 2)
        #expect(effective.nodes.contains { $0.id == "group:wiki" && $0.kind == "group" })
        #expect(!effective.nodes.contains { $0.id == "wiki:a" })
        // Both write edges rerouted to the super-node and deduped into one.
        #expect(effective.edges.count == 1)
        #expect(effective.edges.first?.target == "group:wiki")
    }

    @Test("toggling the same scheme twice restores the original graph")
    internal func collapseRoundTrips() {
        let vm = groupedVM()
        vm.toggleGroupCollapsed("wiki")
        #expect(vm.isGroupCollapsed("wiki"))
        vm.toggleGroupCollapsed("wiki")
        #expect(!vm.isGroupCollapsed("wiki"))
        #expect(vm.effectiveGraph().nodes.count == 3)
    }

    // MARK: - categoryHulls

    private func cron(_ id: String, _ label: String) -> CronGraphNode {
        CronGraphNode(id: id, kind: "cron", type: "cron", label: label,
                      schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil)
    }

    @Test("cron category hulls group jobs by top-level folder, keeping only ≥2-member folders")
    internal func categoryHullsGroupByFolder() {
        let vm = CronGraphViewModel()
        vm.setGraphForTesting(CronGraph(
            nodes: [
                cron("a", "life/training/run"),
                cron("b", "life/reading"),
                cron("c", "work/standup"),
                CronGraphNode(id: "wiki:x", kind: "artifact", type: "wiki", label: "x",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
            ],
            edges: []
        ))
        let hulls = vm.categoryHulls
        // `life` has two jobs; `work` has one (dropped); resources never form a category hull.
        #expect(hulls.count == 1)
        #expect(hulls.first?.key == "life")
        #expect(hulls.first?.memberIDs.sorted() == ["a", "b"])
        #expect(!hulls.contains { $0.key == "wiki" || $0.key == "work" })
    }

    // MARK: - edgeLegend

    @Test("edge legend lists present types in dataflow order and folds side-effects into Delivers")
    internal func edgeLegendOrdersAndFolds() {
        let vm = CronGraphViewModel()
        vm.setGraphForTesting(CronGraph(
            nodes: [
                cron("job", "job"),
                CronGraphNode(id: "wiki:a", kind: "artifact", type: "wiki", label: "a",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
                CronGraphNode(id: "telegram:x", kind: "sink", type: "telegram", label: "x",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
                CronGraphNode(id: "src:y", kind: "source", type: "src", label: "y",
                              schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil),
            ],
            edges: [
                CronGraphEdge(source: "src:y", target: "job", type: "reads"),
                CronGraphEdge(source: "job", target: "wiki:a", type: "writes"),
                CronGraphEdge(source: "job", target: "telegram:x", type: "notify"),
            ]
        ))
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.setupSimulation()
        let legend = vm.edgeLegend
        // reads → writes → (feeds absent) → the non-structural `notify` folds into one Delivers row.
        #expect(legend.map(\.type) == ["reads", "writes", "deliver"])
        #expect(legend.map(\.label) == ["Reads", "Writes", "Delivers"])
    }

    // MARK: - displayLabel

    @Test("canvas label drops the cron category prefix, leaving ungrouped crons and other kinds intact")
    internal func displayLabelStripsCategoryPrefix() {
        let vm = CronGraphViewModel()
        // The tint + hull already carry the folder, so the leaf is enough.
        #expect(vm.displayLabel(forKind: "cron", label: "projection/x402") == "x402")
        #expect(vm.displayLabel(forKind: "cron", label: "life/training/morning-run") == "morning-run")
        // No category → nothing to strip.
        #expect(vm.displayLabel(forKind: "cron", label: "db-backup") == "db-backup")
        // Non-cron labels are shown verbatim.
        #expect(vm.displayLabel(forKind: "artifact", label: "wiki:events/a") == "wiki:events/a")
    }

    // MARK: - zoomAtPoint / zoomAtCenter

    @Test("zoomAtPoint scales zoom and keeps the anchor point fixed")
    internal func zoomAtPointHoldsAnchor() {
        let vm = CronGraphViewModel()
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.zoom = 1.0
        vm.panOffset = .zero
        let anchor = CGPoint(x: 100, y: 50)
        vm.zoomAtPoint(factor: 2.0, around: anchor)
        #expect(vm.zoom == 2.0)
        // pan compensates by point * (oldZoom - newZoom) = 100 * (1 - 2) = -100.
        #expect(vm.panOffset.width == -100)
        #expect(vm.panOffset.height == -50)
    }

    @Test("zoomAtPoint clamps to the usable [0.3, 5.0] range")
    internal func zoomClampsToRange() {
        let vm = CronGraphViewModel()
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.zoom = 1.0
        // Blow past the ceiling — repeated zoom-in never exceeds 5.0.
        for _ in 0..<20 { vm.zoomAtCenter(2.0) }
        #expect(vm.zoom == 5.0)
        // And past the floor — repeated zoom-out never drops below 0.3.
        for _ in 0..<40 { vm.zoomAtCenter(0.5) }
        #expect(vm.zoom == 0.3)
    }

    @Test("zoomAtPoint ignores non-finite or non-positive factors")
    internal func zoomIgnoresBadFactors() {
        let vm = CronGraphViewModel()
        vm.zoom = 1.4
        vm.zoomAtPoint(factor: 0, around: .zero)
        vm.zoomAtPoint(factor: -1, around: .zero)
        vm.zoomAtPoint(factor: .infinity, around: .zero)
        #expect(vm.zoom == 1.4)
    }
}
