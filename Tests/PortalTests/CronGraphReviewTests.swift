import CoreGraphics
import Foundation
import Testing
@testable import Portal

/// The review side of the diff: what the drawer opens and what the canvas is
/// asked to draw for it.
///
/// The load-bearing assertion in here is that the highlight is *derived* from the
/// diff and then narrowed to what's drawn, never recomputed — the same guard
/// `hulledCategoryFolders` and `categoryHulls` get, for the same reason. A
/// highlight that drifts from the list beside it is worse than no highlight,
/// because both look authoritative.
@MainActor
@Suite("Cron graph revision review")
internal struct CronGraphReviewTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func job(_ id: String, _ label: String, schedule: String? = "every 60m") -> CronGraphNode {
        CronGraphNode(id: id, kind: "cron", type: "cron", label: label, description: "",
                      schedule: schedule, enabled: true, usesLLM: false, lastStatus: "ok", deliver: nil)
    }

    private func artifact(_ id: String, _ label: String) -> CronGraphNode {
        CronGraphNode(id: id, kind: "artifact", type: "wiki", label: label, description: "",
                      schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil)
    }

    /// A view model whose log holds `revisions` in order and whose canvas is
    /// showing `onScreen` — separate arguments on purpose, because reviewing an
    /// old revision against the current wiring is the case most likely to lie.
    private func reviewing(
        _ revisions: [CronGraph],
        onScreen: CronGraph
    ) throws -> (vm: CronGraphViewModel, log: [CronGraphRevision]) {
        let store = CronGraphRevisionStore(testing: true)
        var recorded: [CronGraphRevision] = []
        for (offset, graph) in revisions.enumerated() {
            recorded.append(try #require(store.observe(graph, at: epoch.addingTimeInterval(Double(offset) * 60))))
        }
        let vm = CronGraphViewModel(revisionStore: store)
        vm.setGraphForTesting(onScreen)
        vm.canvasSize = CGSize(width: 600, height: 400)
        vm.setupSimulation()
        return (vm, recorded)
    }

    private func onScreenIDs(_ vm: CronGraphViewModel) -> Set<String> {
        Set(vm.simNodes.map(\.id))
    }

    private func highlightedIDs(_ vm: CronGraphViewModel) -> Set<String> {
        Set(vm.reviewedNodeIndices.map { vm.simNodes[$0].id })
    }

    // MARK: - The drift guard

    @Test("what the canvas highlights is exactly the diff's affected nodes, narrowed to what's drawn")
    internal func highlightedNodesEqualTheAffectedSet() throws {
        let before = CronGraph(
            nodes: [job("abc123", "indexing/sweep"), artifact("wiki:x402", "x402")],
            edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")]
        )
        let after = CronGraph(
            nodes: [job("abc123", "indexing/sweep", schedule: "every 6h"),
                    artifact("wiki:x402", "x402"),
                    artifact("wiki:mpp", "mpp")],
            edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes"),
                    CronGraphEdge(source: "wiki:mpp", target: "abc123", type: "reads")]
        )
        let (vm, log) = try reviewing([before, after], onScreen: after)
        vm.toggleReview(of: try #require(log.last))

        let diff = try #require(vm.reviewedDiff)
        #expect(!diff.isEmpty)
        #expect(highlightedIDs(vm) == diff.affectedNodeIDs.intersection(onScreenIDs(vm)))
        // Not vacuous: this pair's affected nodes are all on screen, so the
        // highlight is the whole affected set.
        #expect(highlightedIDs(vm) == diff.affectedNodeIDs)
        #expect(vm.reviewedChangesNotOnScreen == 0)
        // And the colors are the same derivation as the set, not a second walk.
        #expect(vm.reviewedNodeIndices == Set(vm.reviewedNodePolarities.keys))
    }

    @Test("a graph with no review open highlights nothing")
    internal func nothingIsHighlightedUntilARevisionIsOpened() throws {
        let graph = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])
        let (vm, _) = try reviewing([graph], onScreen: graph)
        #expect(vm.reviewedRevisionID == nil)
        #expect(vm.reviewedDiff == nil)
        #expect(vm.reviewedNodeIndices.isEmpty)
        #expect(vm.reviewedAddedLinkIndices.isEmpty)
        #expect(vm.reviewedRemovedLinks.isEmpty)
        #expect(vm.reviewedChangesNotOnScreen == 0)
    }

    // MARK: - Opening and closing

    @Test("clicking a row opens it, clicking it again closes it, clicking another switches")
    internal func toggleOpensClosesAndSwitches() throws {
        let first = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])
        let second = CronGraph(nodes: [job("abc123", "indexing/sweep", schedule: "every 6h")], edges: [])
        let third = CronGraph(nodes: [job("abc123", "indexing/sweep", schedule: "every 12h")], edges: [])
        let (vm, log) = try reviewing([first, second, third], onScreen: third)

        vm.toggleReview(of: log[1])
        #expect(vm.reviewedRevisionID == log[1].id)
        #expect(vm.reviewedDiff?.changes.map(\.summary) == ["indexing/sweep runs every 6h (was every 60m)"])

        vm.toggleReview(of: log[2])
        #expect(vm.reviewedRevisionID == log[2].id)
        #expect(vm.reviewedDiff?.changes.map(\.summary) == ["indexing/sweep runs every 12h (was every 6h)"])

        vm.toggleReview(of: log[2])
        #expect(vm.reviewedRevisionID == nil)
        #expect(vm.reviewedDiff == nil)
    }

    @Test("closing the drawer clears the review with it")
    internal func closingTheDrawerClearsTheReview() throws {
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "indexing/sweep", schedule: "every 6h")], edges: [])
        let (vm, log) = try reviewing([before, after], onScreen: after)

        vm.showRevisions = true
        vm.toggleReview(of: try #require(log.last))
        #expect(!vm.reviewedNodeIndices.isEmpty)

        // Otherwise the graph stays tinted with nothing on screen to say against
        // which revision, and no way to dismiss it.
        vm.showRevisions = false
        #expect(vm.reviewedRevisionID == nil)
        #expect(vm.reviewedDiff == nil)
        #expect(vm.reviewedNodeIndices.isEmpty)

        vm.showRevisions = true
        #expect(vm.reviewedRevisionID == nil)
    }

    @Test("a revision whose predecessor was trimmed opens with no diff rather than a wrong one")
    internal func aTrimmedPredecessorOpensEmpty() throws {
        let store = CronGraphRevisionStore(testing: true)
        for index in 0..<205 {
            store.observe(CronGraph(nodes: [job("abc123", "indexing/sweep", schedule: "every \(index)m")],
                                    edges: []),
                          at: epoch.addingTimeInterval(Double(index)))
        }
        let vm = CronGraphViewModel(revisionStore: store)
        let oldest = try #require(store.revisions.first)

        vm.toggleReview(of: oldest)
        // Open — the drawer needs to know which row to expand so it can say the
        // predecessor is gone — but with nothing to highlight.
        #expect(vm.reviewedRevisionID == oldest.id)
        #expect(vm.reviewedDiff == nil)
        #expect(vm.reviewedNodeIndices.isEmpty)
    }

    // MARK: - Edges

    @Test("an added edge resolves to the link the canvas draws")
    internal func addedEdgesResolveToLinkIndices() throws {
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep"), artifact("wiki:x402", "x402")],
                               edges: [])
        let after = CronGraph(nodes: before.nodes,
                              edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")])
        let (vm, log) = try reviewing([before, after], onScreen: after)
        vm.toggleReview(of: try #require(log.last))

        let lit = vm.reviewedAddedLinkIndices
        #expect(lit.count == 1)
        let index = try #require(lit.first)
        let (si, ti) = vm.simLinks[index]
        #expect(vm.simNodes[si].id == "abc123")
        #expect(vm.simNodes[ti].id == "wiki:x402")
        // Retyping would be a different link: edge identity includes the type.
        #expect(vm.simLinkTypes[index] == "writes")
    }

    @Test("a removed edge is placed from the diff, since it isn't in the graph being drawn")
    internal func removedEdgesAreGhostedFromTheDiff() throws {
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep"), artifact("wiki:x402", "x402")],
                               edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")])
        let after = CronGraph(nodes: before.nodes, edges: [])
        let (vm, log) = try reviewing([before, after], onScreen: after)
        vm.toggleReview(of: try #require(log.last))

        #expect(vm.simLinks.isEmpty) // nothing in the drawn graph to look up
        let ghosts = vm.reviewedRemovedLinks
        #expect(ghosts.count == 1)
        let ghost = try #require(ghosts.first)
        #expect(vm.simNodes[ghost.sourceIndex].id == "abc123")
        #expect(vm.simNodes[ghost.targetIndex].id == "wiki:x402")
        #expect(ghost.type == "writes")
    }

    @Test("a removed edge with no endpoint left on screen is counted, not drawn")
    internal func unplaceableGhostsAreCountedInstead() throws {
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep"), artifact("wiki:x402", "x402")],
                               edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")])
        let (vm, log) = try reviewing([before, .empty], onScreen: .empty)
        vm.toggleReview(of: try #require(log.last))

        let diff = try #require(vm.reviewedDiff)
        #expect(vm.reviewedRemovedLinks.isEmpty)
        #expect(vm.reviewedNodeIndices.isEmpty)
        // Every statement in the diff names something that's gone, and the drawer
        // says so rather than showing an untouched graph beside a change list.
        #expect(vm.reviewedChangesNotOnScreen == diff.count)
        #expect(diff.count > 0)
    }

    @Test("reviewing an old revision admits the parts of it that no longer exist")
    internal func reviewingAnOldRevisionAdmitsWhatIsGone() throws {
        // The log: a job alone, then a second job added, then that second job
        // deleted again. The canvas shows the present, so opening the middle
        // revision highlights a change to a node that isn't there.
        let alone = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])
        let pair = CronGraph(nodes: [job("abc123", "indexing/sweep"), job("def456", "indexing/mpp")], edges: [])
        let (vm, log) = try reviewing([alone, pair, alone], onScreen: alone)

        vm.toggleReview(of: log[1])
        let diff = try #require(vm.reviewedDiff)
        #expect(diff.changes.map(\.summary) == ["indexing/mpp added"])
        #expect(vm.reviewedNodeIndices.isEmpty)
        #expect(vm.reviewedChangesNotOnScreen == 1)
        // Still equal to the intersection — the guard holds in the lossy case too,
        // which is the one where a recomputed highlight would quietly disagree.
        #expect(highlightedIDs(vm) == diff.affectedNodeIDs.intersection(onScreenIDs(vm)))
    }

    // MARK: - Tint

    @Test("a node's tint takes the strongest claim among the statements naming it")
    internal func polarityTakesTheStrongestClaim() throws {
        let before = CronGraph(
            nodes: [job("abc123", "indexing/sweep"), job("def456", "indexing/mpp"),
                    artifact("wiki:x402", "x402")],
            edges: [CronGraphEdge(source: "def456", target: "wiki:x402", type: "writes")]
        )
        let after = CronGraph(
            nodes: [job("abc123", "indexing/sweep", schedule: "every 6h"), job("def456", "indexing/mpp"),
                    artifact("wiki:x402", "x402"), job("ghi789", "indexing/new")],
            edges: [CronGraphEdge(source: "ghi789", target: "wiki:x402", type: "writes")]
        )
        let (vm, log) = try reviewing([before, after], onScreen: after)
        vm.toggleReview(of: try #require(log.last))

        let byID = Dictionary(vm.reviewedNodePolarities.map { (vm.simNodes[$0.key].id, $0.value) },
                              uniquingKeysWith: { first, _ in first })
        // Only rescheduled — an edit.
        #expect(byID["abc123"] == .modified)
        // Added, and wired up in the same revision: still "new here".
        #expect(byID["ghi789"] == .added)
        // Lost its only output edge but still exists: "something here is gone".
        #expect(byID["def456"] == .removed)
        // Both an added and a removed edge name it, and new outranks gone.
        #expect(byID["wiki:x402"] == .added)
    }
}
