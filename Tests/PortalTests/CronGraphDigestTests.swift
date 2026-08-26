import Foundation
import Testing
@testable import Portal

/// Coverage for the dataflow graph's commitment. Pure hashing over a canonical
/// form — no gateway, no view, no layout.
@Suite("Cron graph commitment")
internal struct CronGraphDigestTests {

    private func node(
        id: String,
        kind: String = "cron",
        type: String = "cron",
        label: String = "job",
        description: String = "",
        schedule: String? = "every 60m",
        enabled: Bool = true,
        usesLLM: Bool = false,
        lastStatus: String? = "ok",
        deliver: String? = nil
    ) -> CronGraphNode {
        CronGraphNode(id: id, kind: kind, type: type, label: label, description: description,
                      schedule: schedule, enabled: enabled, usesLLM: usesLLM,
                      lastStatus: lastStatus, deliver: deliver)
    }

    private func graph(
        _ nodes: [CronGraphNode],
        _ edges: [CronGraphEdge] = []
    ) -> CronGraph {
        CronGraph(nodes: nodes, edges: edges)
    }

    private var base: CronGraph {
        graph(
            [
                node(id: "abc123", label: "indexing/solana sweep"),
                node(id: "def456", label: "indexing/x402 wiki projection"),
                node(id: "wiki:x402", kind: "artifact", type: "wiki", label: "x402",
                     schedule: nil, lastStatus: nil),
            ],
            [
                CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes"),
                CronGraphEdge(source: "wiki:x402", target: "def456", type: "reads"),
            ]
        )
    }

    // MARK: - Shape

    @Test("the digest is a full SHA-256 with a 12-hex display form")
    internal func digestShape() {
        let digest = CronGraphDigest.over(base)
        #expect(digest.hex.count == 64)
        #expect(digest.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(digest.short.count == 12)
        #expect(digest.hex.hasPrefix(digest.short))
    }

    @Test("the empty-graph commitment is a real value, not a sentinel")
    internal func emptyGraphDigest() {
        // "Nothing loaded yet" and "loaded, and there are no jobs" are genuinely
        // the same configuration, so they get the same commitment rather than one
        // of them getting a nil-ish placeholder.
        #expect(CronGraphDigest.emptyGraph == CronGraphDigest.over(.empty))
        #expect(CronGraphDigest.emptyGraph != CronGraphDigest.over(base))
    }

    // MARK: - Stability

    @Test("the gateway's ordering does not change the commitment")
    internal func digestIsStableAcrossOrdering() {
        // `cron.graph` makes no ordering promise, and a reordered response is the
        // same dataflow. If ordering leaked in, every fetch could look like a
        // change.
        let shuffled = graph(base.nodes.reversed(), base.edges.reversed())
        #expect(CronGraphDigest.over(shuffled) == CronGraphDigest.over(base))
    }

    @Test("service health does not mint a revision")
    internal func livenessIsExcluded() {
        // The graph is re-fetched every 10s for service health. A commitment that
        // covered `lastStatus` would produce a new revision on that timer forever
        // — a history of the poll loop rather than of anyone's changes.
        let sick = graph(
            base.nodes.map {
                node(id: $0.id, kind: $0.kind, type: $0.type, label: $0.label,
                     description: $0.description, schedule: $0.schedule, enabled: $0.enabled,
                     usesLLM: $0.usesLLM, lastStatus: "error", deliver: $0.deliver)
            },
            base.edges
        )
        #expect(CronGraphDigest.over(sick) == CronGraphDigest.over(base))
    }

    // MARK: - What counts as a change

    @Test("every configured field moves the commitment")
    internal func configurationChangesMintARevision() {
        let original = CronGraphDigest.over(base)
        var mutations: [String: CronGraph] = [:]

        mutations["schedule"] = graph(
            [node(id: "abc123", label: "indexing/solana sweep", schedule: "every 6h")]
                + base.nodes.dropFirst(),
            base.edges
        )
        mutations["enabled"] = graph(
            [node(id: "abc123", label: "indexing/solana sweep", enabled: false)]
                + base.nodes.dropFirst(),
            base.edges
        )
        mutations["usesLLM"] = graph(
            [node(id: "abc123", label: "indexing/solana sweep", usesLLM: true)]
                + base.nodes.dropFirst(),
            base.edges
        )
        mutations["deliver"] = graph(
            [node(id: "abc123", label: "indexing/solana sweep", deliver: "telegram")]
                + base.nodes.dropFirst(),
            base.edges
        )
        mutations["description"] = graph(
            [node(id: "abc123", label: "indexing/solana sweep", description: "# what it does")]
                + base.nodes.dropFirst(),
            base.edges
        )
        // A recategorization is a rename, and a rename is a change.
        mutations["label"] = graph(
            [node(id: "abc123", label: "projection/solana sweep")] + base.nodes.dropFirst(),
            base.edges
        )
        mutations["node added"] = graph(base.nodes + [node(id: "ghi789", label: "work/standup")],
                                       base.edges)
        mutations["node removed"] = graph(Array(base.nodes.dropLast()), base.edges)
        // The edge cases that matter most: a job quietly reading something new.
        mutations["edge added"] = graph(
            base.nodes,
            base.edges + [CronGraphEdge(source: "def456", target: "wiki:x402", type: "writes")]
        )
        mutations["edge removed"] = graph(base.nodes, Array(base.edges.dropLast()))
        mutations["edge retyped"] = graph(
            base.nodes,
            [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "reads")] + base.edges.dropFirst()
        )

        for (what, mutated) in mutations {
            #expect(CronGraphDigest.over(mutated) != original, "\(what) should mint a new revision")
        }
    }

    @Test("a cleared schedule is not the same as no schedule")
    internal func nilAndEmptyAreDistinct() {
        // `?? ""` would collapse these and hide the edit between them.
        let none = graph([node(id: "abc123", schedule: nil)])
        let cleared = graph([node(id: "abc123", schedule: "")])
        #expect(CronGraphDigest.over(none) != CronGraphDigest.over(cleared))
    }

    @Test("a field value cannot be mistaken for a field boundary")
    internal func fieldBoundariesCannotBeForged() {
        // Node ids are `scheme:value` and job labels are `folder/name`, so any
        // plain separator already appears inside the values it separates. Joined
        // on `:`, both of these encode as `n:wiki:a:artifact:wiki:a` — two
        // different graphs with one address, which for a content address is the
        // failure that matters.
        let left = graph([node(id: "wiki:a", kind: "artifact", type: "wiki", label: "a",
                               schedule: nil, lastStatus: nil)])
        let right = graph([node(id: "wiki", kind: "a:artifact", type: "wiki", label: "a",
                                schedule: nil, lastStatus: nil)])
        #expect(CronGraphDigest.over(left) != CronGraphDigest.over(right))
    }

    // MARK: - Commitment vs layout

    @Test("a schedule edit is a new revision but does not move a node")
    internal func layoutFormIgnoresConfiguration() {
        // The two field sets exist to answer two different questions, and this is
        // the case that separates them: rebuilding the simulation here would
        // scramble a settled graph for a change that places nothing.
        let rescheduled = graph(
            [node(id: "abc123", label: "indexing/solana sweep", schedule: "every 6h")]
                + base.nodes.dropFirst(),
            base.edges
        )
        #expect(CronGraphDigest.over(rescheduled) != CronGraphDigest.over(base))
        #expect(CronGraphDigest.layoutForm(rescheduled) == CronGraphDigest.layoutForm(base))
    }

    @Test("a rewiring is both a new revision and a re-layout")
    internal func layoutFormFollowsTopology() {
        let rewired = graph(
            base.nodes,
            base.edges + [CronGraphEdge(source: "def456", target: "wiki:x402", type: "writes")]
        )
        #expect(CronGraphDigest.over(rewired) != CronGraphDigest.over(base))
        #expect(CronGraphDigest.layoutForm(rewired) != CronGraphDigest.layoutForm(base))
    }

    @Test("the layout form is a strict subset of what the commitment covers")
    internal func layoutFormIsASubset() {
        // Nothing may be layout-relevant without also being part of the
        // configuration: a graph that re-layouts without minting a revision would
        // be a change with no record of it.
        let rewired = graph(
            base.nodes,
            base.edges + [CronGraphEdge(source: "def456", target: "wiki:x402", type: "writes")]
        )
        let relabeled = graph(
            [node(id: "abc123", label: "renamed")] + base.nodes.dropFirst(),
            base.edges
        )
        for changed in [rewired, relabeled] {
            #expect(CronGraphDigest.layoutForm(changed) != CronGraphDigest.layoutForm(base))
            #expect(CronGraphDigest.over(changed) != CronGraphDigest.over(base))
        }
    }
}

/// The view model's published commitment, which is what the chip renders.
@MainActor
@Suite("Cron graph commitment — view model")
internal struct CronGraphDigestViewModelTests {

    private func cron(_ id: String, schedule: String?, lastStatus: String?) -> CronGraphNode {
        CronGraphNode(id: id, kind: "cron", type: "cron", label: "indexing/sweep",
                      description: "", schedule: schedule, enabled: true, usesLLM: false,
                      lastStatus: lastStatus, deliver: nil)
    }

    @Test("an unloaded graph already shows a commitment")
    internal func startsAtTheEmptyGraphCommitment() {
        #expect(CronGraphViewModel().digest == CronGraphDigest.emptyGraph)
    }

    @Test("the published commitment tracks the graph")
    internal func digestFollowsGraph() {
        let vm = CronGraphViewModel()
        vm.setGraphForTesting(CronGraph(nodes: [cron("a", schedule: "every 60m", lastStatus: "ok")],
                                        edges: []))
        let first = vm.digest
        #expect(first != CronGraphDigest.emptyGraph)

        // A health-only refresh must leave the chip alone — otherwise it flickers
        // a new hash every 10 seconds and stops meaning anything.
        vm.setGraphForTesting(CronGraph(nodes: [cron("a", schedule: "every 60m", lastStatus: "error")],
                                        edges: []))
        #expect(vm.digest == first)

        vm.setGraphForTesting(CronGraph(nodes: [cron("a", schedule: "every 6h", lastStatus: "error")],
                                        edges: []))
        #expect(vm.digest != first)
    }
}
