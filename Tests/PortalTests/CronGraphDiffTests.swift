import Foundation
import Testing
@testable import Portal

/// Coverage for the structural diff between two graph revisions — the typed
/// statements a person reads, not a text diff of a serialization.
@Suite("Cron graph diff")
internal struct CronGraphDiffTests {

    private func job(
        _ id: String,
        _ label: String,
        schedule: String? = "every 60m",
        enabled: Bool = true,
        usesLLM: Bool = false,
        deliver: String? = nil
    ) -> CronGraphNode {
        CronGraphNode(id: id, kind: "cron", type: "cron", label: label, description: "",
                      schedule: schedule, enabled: enabled, usesLLM: usesLLM,
                      lastStatus: "ok", deliver: deliver)
    }

    private func resource(_ id: String, _ label: String, kind: String = "artifact") -> CronGraphNode {
        CronGraphNode(id: id, kind: kind, type: "wiki", label: label, description: "",
                      schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil)
    }

    private func service(_ id: String, _ label: String, description: String = "a dashboard") -> CronGraphNode {
        CronGraphNode(id: id, kind: "service", type: "service", label: label,
                      description: description, schedule: nil, enabled: true, usesLLM: false,
                      lastStatus: nil, deliver: nil)
    }

    /// One job writing one artifact.
    private var base: CronGraph {
        CronGraph(
            nodes: [job("abc123", "indexing/solana sweep"), resource("wiki:x402", "x402")],
            edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")]
        )
    }

    private func diff(_ before: CronGraph, _ after: CronGraph) -> CronGraphDiff {
        CronGraphDiff.between(before, after)
    }

    private func summaries(_ before: CronGraph, _ after: CronGraph) -> [String] {
        diff(before, after).changes.map(\.summary)
    }

    // MARK: - Nothing, and everything

    @Test("the same revision twice has nothing to say")
    internal func identicalGraphsDiffEmpty() {
        let diff = diff(base, base)
        #expect(diff.isEmpty)
        #expect(diff.affectedNodeIDs.isEmpty)
        #expect(diff.addedEdgeIDs.isEmpty)
        #expect(diff.removedEdges.isEmpty)
    }

    @Test("an empty graph becoming populated reads as all additions")
    internal func emptyToPopulatedIsAllAdditions() {
        // The first revision on record has nothing behind it, so this is the shape
        // the very first drawer row renders. It must not throw and must not claim
        // anything was removed.
        let diff = diff(.empty, base)
        #expect(diff.changes.allSatisfy { $0.polarity == .added })
        #expect(diff.changes.contains { $0.summary == "indexing/solana sweep added" })
        #expect(diff.changes.contains { $0.summary == "indexing/solana sweep now writes x402" })
        #expect(diff.removedEdges.isEmpty)
    }

    @Test("a job and its wiring going away reads as all removals")
    internal func populatedToEmptyIsAllRemovals() {
        let diff = diff(base, .empty)
        #expect(diff.changes.allSatisfy { $0.polarity == .removed })
        #expect(diff.changes.contains { $0.summary == "indexing/solana sweep removed" })
        // The removed edge keeps both labels even though neither node exists in the
        // graph being drawn — nothing is left to look them up in.
        #expect(diff.changes.contains { $0.summary == "indexing/solana sweep no longer writes x402" })
        #expect(diff.removedEdges.count == 1)
    }

    // MARK: - Rename vs recategorize

    @Test("a path-only rewrite is a move, not a rename")
    internal func pathOnlyChangeIsAMove() {
        // The category lives in the name, so refiling and renaming are the same
        // wire operation. Reporting `projection/x402` → `indexing/x402` as a rename
        // would claim the job's identity changed when only its folder did.
        let before = CronGraph(nodes: [job("abc123", "projection/x402")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "indexing/x402")], edges: [])
        #expect(summaries(before, after) == ["x402 moved to indexing"])
        #expect(diff(before, after).changes.first?.polarity == .modified)
    }

    @Test("a leaf change within the same folder is a rename")
    internal func leafChangeIsARename() {
        let before = CronGraph(nodes: [job("abc123", "indexing/x402")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "indexing/x402 wiki")], edges: [])
        #expect(summaries(before, after) == ["indexing/x402 renamed to indexing/x402 wiki"])
    }

    @Test("changing both folder and leaf is a rename, stated in full")
    internal func bothChangedIsARename() {
        // It really is a new identity, and the full names carry the move as well —
        // calling it a move would drop the leaf change from the sentence.
        let before = CronGraph(nodes: [job("abc123", "projection/x402")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "indexing/x402 wiki")], edges: [])
        #expect(summaries(before, after) == ["projection/x402 renamed to indexing/x402 wiki"])
    }

    @Test("a job pulled out of every folder moves to Ungrouped")
    internal func moveToRootReadsAsUngrouped() {
        let before = CronGraph(nodes: [job("abc123", "indexing/x402")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "x402")], edges: [])
        #expect(summaries(before, after) == ["x402 moved to Ungrouped"])
    }

    @Test("a deeper move names the whole destination path")
    internal func nestedMoveNamesThePath() {
        let before = CronGraph(nodes: [job("abc123", "x402")], edges: [])
        let after = CronGraph(nodes: [job("abc123", "indexing/wiki/x402")], edges: [])
        #expect(summaries(before, after) == ["x402 moved to indexing › wiki"])
    }

    // MARK: - Configuration

    @Test("every configured field states its own change")
    internal func configurationFieldsEachSpeak() {
        // The digest mints a revision for each of these, so the diff owes a
        // sentence for each: a revision that says "something changed" and then
        // shows an empty diff is worse than no log.
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])

        let rescheduled = CronGraph(nodes: [job("abc123", "indexing/sweep", schedule: "every 6h")], edges: [])
        #expect(summaries(before, rescheduled) == ["indexing/sweep runs every 6h (was every 60m)"])

        let disabled = CronGraph(nodes: [job("abc123", "indexing/sweep", enabled: false)], edges: [])
        #expect(summaries(before, disabled) == ["indexing/sweep disabled"])
        #expect(summaries(disabled, before) == ["indexing/sweep enabled"])

        let modelled = CronGraph(nodes: [job("abc123", "indexing/sweep", usesLLM: true)], edges: [])
        #expect(summaries(before, modelled) == ["indexing/sweep now burns a model"])
        #expect(summaries(modelled, before) == ["indexing/sweep no longer burns a model"])

        let delivering = CronGraph(nodes: [job("abc123", "indexing/sweep", deliver: "telegram")], edges: [])
        #expect(summaries(before, delivering) == ["indexing/sweep now delivers to telegram"])
        #expect(summaries(delivering, before) == ["indexing/sweep no longer delivers anywhere"])
    }

    @Test("a cleared schedule is not the same as no schedule")
    internal func clearedAndAbsentSchedulesDiffer() {
        // The digest distinguishes them, so the sentence has to as well — "runs on
        // no schedule" and "runs on a cleared schedule" are different states.
        let none = CronGraph(nodes: [job("abc123", "sweep", schedule: nil)], edges: [])
        let cleared = CronGraph(nodes: [job("abc123", "sweep", schedule: "")], edges: [])
        #expect(summaries(none, cleared) == ["sweep runs on a cleared schedule (was on no schedule)"])
        #expect(summaries(cleared, none) == ["sweep runs on no schedule (was on a cleared schedule)"])
    }

    @Test("a service description edit is reported without diffing prose")
    internal func descriptionChangeIsStatedNotDiffed() {
        let before = CronGraph(nodes: [service("docker:pg", "postgres")], edges: [])
        let after = CronGraph(nodes: [service("docker:pg", "postgres", description: "# the store")], edges: [])
        #expect(summaries(before, after) == ["postgres description edited"])
    }

    @Test("several edits to one job each get their own line")
    internal func multipleFieldChangesAreSeparateStatements() {
        let before = CronGraph(nodes: [job("abc123", "indexing/sweep")], edges: [])
        let after = CronGraph(
            nodes: [job("abc123", "indexing/nightly sweep", schedule: "every 6h", enabled: false)],
            edges: []
        )
        let diff = diff(before, after)
        #expect(diff.count == 3)
        // Identity first, then configuration — a stable reading order.
        #expect(diff.changes.map(\.rank) == diff.changes.map(\.rank).sorted())
        #expect(Set(diff.changes.map(\.id)).count == 3)
    }

    // MARK: - Services

    @Test("services appearing and disappearing are their own statements")
    internal func servicesAreNotResources() {
        // A service is something someone runs, not a consequence of wiring, so it
        // says so even with no edges attached.
        let after = CronGraph(nodes: base.nodes + [service("docker:pg", "postgres")], edges: base.edges)
        #expect(summaries(base, after) == ["postgres service appeared"])
        #expect(summaries(after, base) == ["postgres service disappeared"])
    }

    // MARK: - Edges, stated as dataflow

    @Test("a new input reads as the job reading something new")
    internal func edgeAdditionsReadAsDataflow() {
        let after = CronGraph(
            nodes: base.nodes + [resource("wiki:mpp", "mpp", kind: "source")],
            edges: base.edges + [CronGraphEdge(source: "wiki:mpp", target: "abc123", type: "reads")]
        )
        // The resource itself isn't announced separately — the sentence already
        // names it, and an artifact exists *because* something reads or writes it.
        #expect(summaries(base, after) == ["indexing/solana sweep now reads mpp"])
        #expect(diff(base, after).addedEdgeIDs == ["wiki:mpp->abc123:reads"])
        #expect(diff(base, after).affectedNodeIDs == ["abc123", "wiki:mpp"])
    }

    @Test("each edge type gets the verb that matches it")
    internal func everyEdgeTypeHasItsOwnSentence() {
        let nodes = [
            job("abc123", "sweep"), job("def456", "projection"),
            resource("wiki:x402", "x402"), resource("telegram:ops", "ops", kind: "sink"),
        ]
        let before = CronGraph(nodes: nodes, edges: [])
        let after = CronGraph(nodes: nodes, edges: [
            CronGraphEdge(source: "wiki:x402", target: "abc123", type: "reads"),
            CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes"),
            CronGraphEdge(source: "abc123", target: "def456", type: "feeds"),
            CronGraphEdge(source: "abc123", target: "telegram:ops", type: "telegram"),
        ])
        #expect(Set(summaries(before, after)) == [
            "sweep now reads x402",
            "sweep now writes x402",
            "sweep now feeds projection",
            "sweep now delivers to ops via telegram",
        ])
        #expect(Set(summaries(after, before)) == [
            "sweep no longer reads x402",
            "sweep no longer writes x402",
            "sweep no longer feeds projection",
            "sweep no longer delivers to ops via telegram",
        ])
    }

    @Test("retyping an edge is a removal plus an addition")
    internal func retypedEdgesAreTwoStatements() {
        // Edge identity includes the type, and it should: a job that used to write
        // an artifact and now only reads it changed direction of dataflow, which is
        // two facts, not one edited one.
        let after = CronGraph(
            nodes: base.nodes,
            edges: [CronGraphEdge(source: "wiki:x402", target: "abc123", type: "reads")]
        )
        #expect(Set(summaries(base, after)) == [
            "indexing/solana sweep now reads x402",
            "indexing/solana sweep no longer writes x402",
        ])
    }

    @Test("removed edges survive as whole edges, not just ids")
    internal func removedEdgesCanBeRedrawn() {
        // The canvas ghosts them in as dashed lines, and they are by definition not
        // in the graph it's drawing — an id alone couldn't be laid out.
        let after = CronGraph(nodes: base.nodes, edges: [])
        let diff = diff(base, after)
        #expect(diff.removedEdges == [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")])
        #expect(diff.addedEdgeIDs.isEmpty)
    }

    // MARK: - Resources

    @Test("an orphan resource is still reported")
    internal func resourcesWithNoEdgeChangeAreNotSwallowed() {
        // Resource statements are suppressed when an edge change already names the
        // node, but a resource arriving with no wiring to explain it is odd, and a
        // diff that swallows odd is a diff you can't trust.
        let after = CronGraph(nodes: base.nodes + [resource("wiki:orphan", "orphan")], edges: base.edges)
        #expect(summaries(base, after) == ["orphan appeared"])
        #expect(summaries(after, base) == ["orphan disappeared"])
    }

    // MARK: - Determinism

    @Test("the same pair of revisions always diffs the same way")
    internal func diffIsStableAcrossInputOrdering() {
        // Two readings of one pair of revisions have to match, or a diff can't be
        // compared against the one in yesterday's screenshot. The gateway makes no
        // ordering promise, so reordering must not reshuffle the output.
        let after = CronGraph(
            nodes: [job("abc123", "indexing/solana sweep", schedule: "every 6h"),
                    resource("wiki:x402", "x402"),
                    job("def456", "indexing/mpp")],
            edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes"),
                    CronGraphEdge(source: "wiki:x402", target: "def456", type: "reads")]
        )
        let shuffled = CronGraph(nodes: after.nodes.reversed(), edges: after.edges.reversed())
        #expect(diff(base, after) == diff(base, shuffled))
        #expect(summaries(base, after) == summaries(base, shuffled))
    }

    @Test("every statement in a diff has a distinct identity")
    internal func statementIDsAreUnique() {
        // They key SwiftUI rows; a collision silently drops a change from view.
        let after = CronGraph(
            nodes: [job("abc123", "indexing/nightly sweep", schedule: "every 6h", enabled: false),
                    resource("wiki:x402", "x402"),
                    service("docker:pg", "postgres")],
            edges: [CronGraphEdge(source: "wiki:x402", target: "abc123", type: "reads")]
        )
        let diff = diff(base, after)
        #expect(diff.count > 4)
        #expect(Set(diff.changes.map(\.id)).count == diff.count)
    }
}

/// The store's end of the diff: which revision each one is computed against.
@MainActor
@Suite("Cron graph diff — revision log")
internal struct CronGraphDiffRevisionTests {

    private func graph(_ schedule: String) -> CronGraph {
        CronGraph(
            nodes: [CronGraphNode(id: "abc123", kind: "cron", type: "cron", label: "indexing/sweep",
                                  description: "", schedule: schedule, enabled: true, usesLLM: false,
                                  lastStatus: "ok", deliver: nil)],
            edges: []
        )
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a revision diffs against the one before it")
    internal func diffIsAgainstThePrecedingRevision() throws {
        let store = CronGraphRevisionStore(testing: true)
        store.observe(graph("every 60m"), at: epoch)
        let second = try #require(store.observe(graph("every 6h"), at: epoch.addingTimeInterval(60)))

        let diff = try #require(store.diff(for: second))
        #expect(diff.changes.map(\.summary) == ["indexing/sweep runs every 6h (was every 60m)"])
    }

    @Test("the first revision on record diffs against nothing")
    internal func theOldestRevisionDiffsAgainstTheEmptyGraph() throws {
        // It genuinely had no predecessor, so everything in it was news.
        let store = CronGraphRevisionStore(testing: true)
        let first = try #require(store.observe(graph("every 60m"), at: epoch))
        let diff = try #require(store.diff(for: first))
        #expect(diff.changes.map(\.summary) == ["indexing/sweep added"])
    }

    @Test("a revision whose predecessor was trimmed away has no diff to show")
    internal func aTrimmedParentYieldsNoDiff() {
        // Diffing against the empty graph here would report a steady-state graph as
        // freshly built — a change list nobody made. Nil lets the surface say the
        // predecessor is gone.
        let store = CronGraphRevisionStore(testing: true)
        for index in 0..<205 {
            store.observe(graph("every \(index)m"), at: epoch.addingTimeInterval(Double(index)))
        }
        let oldest = store.revisions[0]
        #expect(oldest.parentDigest != nil)
        #expect(store.diff(for: oldest) == nil)
        // Everything after it still diffs normally.
        #expect(store.diff(for: store.revisions[1]) != nil)
    }
}
