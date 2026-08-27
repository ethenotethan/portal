import Foundation
import Testing
@testable import Portal

/// Coverage for the observed revision log. Every store here is built with
/// `init(testing: true)`, which neither reads nor writes the real app-support
/// file — a test must not inherit this machine's history or append to it.
@MainActor
@Suite("Cron graph revision log")
internal struct CronGraphRevisionStoreTests {

    private func node(
        id: String,
        kind: String = "cron",
        label: String = "indexing/solana sweep",
        schedule: String? = "every 60m",
        lastStatus: String? = "ok",
        health: CronServiceHealth? = nil
    ) -> CronGraphNode {
        CronGraphNode(id: id, kind: kind, type: kind, label: label, description: "",
                      schedule: schedule, enabled: true, usesLLM: false,
                      lastStatus: lastStatus, deliver: nil, health: health)
    }

    private var base: CronGraph {
        CronGraph(
            nodes: [node(id: "abc123"), node(id: "wiki:x402", kind: "artifact", label: "x402",
                                             schedule: nil, lastStatus: nil)],
            edges: [CronGraphEdge(source: "abc123", target: "wiki:x402", type: "writes")]
        )
    }

    /// The same dataflow with one job rescheduled — a real change, and one that
    /// moves no node.
    private var rescheduled: CronGraph {
        CronGraph(
            nodes: [node(id: "abc123", schedule: "every 6h")] + base.nodes.dropFirst(),
            edges: base.edges
        )
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Appending

    @Test("the first observation opens the log")
    internal func firstObservationRecordsARevision() throws {
        let store = CronGraphRevisionStore(testing: true)
        let revision = try #require(store.observe(base, at: epoch))

        #expect(store.revisions.count == 1)
        #expect(revision.parentDigest == nil)
        #expect(revision.observedAt == epoch)
        #expect(revision.digest == CronGraphDigest.over(base).hex)
        #expect(store.latest == revision)
        #expect(store.firstObservedAt == epoch)
    }

    @Test("re-observing the same dataflow appends nothing")
    internal func unchangedObservationsAreNotRecorded() {
        // The graph is polled every 10 seconds. A log that appended per poll would
        // be a record of the timer, and would bury the handful of entries that are
        // actually someone's edit.
        let store = CronGraphRevisionStore(testing: true)
        store.observe(base, at: epoch)
        #expect(store.observe(base, at: epoch.addingTimeInterval(10)) == nil)
        #expect(store.revisions.count == 1)
    }

    @Test("liveness moving does not mint a revision")
    internal func runtimeStateIsNotAChange() {
        let store = CronGraphRevisionStore(testing: true)
        store.observe(base, at: epoch)

        let health = CronServiceHealth(status: "unhealthy", probe: "http", target: "/healthz",
                                       checkedAt: "2026-08-26T00:00:00Z", latencyMilliseconds: 41,
                                       message: "")
        let sick = CronGraph(
            nodes: [node(id: "abc123", lastStatus: "error", health: health)] + base.nodes.dropFirst(),
            edges: base.edges
        )
        #expect(store.observe(sick, at: epoch.addingTimeInterval(10)) == nil)
        #expect(store.revisions.count == 1)
    }

    @Test("a stored snapshot is exactly what its own commitment covers")
    internal func snapshotsCarryNoRuntimeState() throws {
        // The invariant a revision has to keep forever: hashing the graph it
        // stores reproduces the digest it stores. Keeping `lastStatus` / `health`
        // in the snapshot wouldn't break the digest, but it would put liveness
        // noise into any later diff between two revisions.
        let store = CronGraphRevisionStore(testing: true)
        let health = CronServiceHealth(status: "healthy", probe: "docker", target: "pg",
                                       checkedAt: "2026-08-26T00:00:00Z", latencyMilliseconds: 3,
                                       message: "up")
        let live = CronGraph(
            nodes: [node(id: "abc123", lastStatus: "ok", health: health)],
            edges: []
        )
        let revision = try #require(store.observe(live, at: epoch))

        #expect(revision.graph.nodes.allSatisfy { $0.lastStatus == nil && $0.health == nil })
        #expect(CronGraphDigest.over(revision.graph).hex == revision.digest)
        // The configuration survived the stripping.
        #expect(revision.graph.nodes.first?.schedule == "every 60m")
    }

    // MARK: - Chaining

    @Test("each revision names the one it succeeded")
    internal func revisionsChainByParentDigest() throws {
        let store = CronGraphRevisionStore(testing: true)
        let first = try #require(store.observe(base, at: epoch))
        let second = try #require(store.observe(rescheduled, at: epoch.addingTimeInterval(60)))

        #expect(second.parentDigest == first.digest)
        #expect(second.digest != first.digest)
        #expect(store.parent(of: second) == first)
        #expect(store.parent(of: first) == nil)
    }

    @Test("a revert is a third observation, not a collision with the first")
    internal func revertsAreRecordedHonestly() {
        // A → B → A. All three are things that happened. Keying a revision on its
        // digest would either drop the third or merge it into the first, and the
        // log would claim the graph never came back.
        let store = CronGraphRevisionStore(testing: true)
        store.observe(base, at: epoch)
        store.observe(rescheduled, at: epoch.addingTimeInterval(60))
        store.observe(base, at: epoch.addingTimeInterval(120))

        #expect(store.revisions.count == 3)
        #expect(store.revisions[2].digest == store.revisions[0].digest)
        #expect(store.revisions[2].id != store.revisions[0].id)
        #expect(Set(store.revisions.map(\.id)).count == 3)
        // Parent is resolved by position, so the revert's parent is the change it
        // undid — not the earlier entry that happens to share its digest.
        #expect(store.parent(of: store.revisions[2]) == store.revisions[1])
    }

    @Test("emptying the graph is a change, not a gap")
    internal func anEmptiedGraphIsARevision() {
        // The store can't distinguish "not fetched yet" from "someone deleted every
        // job" by looking, so it records both and leaves the caller responsible for
        // only handing over graphs that were actually fetched. Guarding on
        // emptiness here would silence the real event to suppress the fake one.
        let store = CronGraphRevisionStore(testing: true)
        store.observe(base, at: epoch)
        store.observe(.empty, at: epoch.addingTimeInterval(60))

        #expect(store.revisions.count == 2)
        #expect(store.revisions[1].digest == CronGraphDigest.emptyGraph.hex)
        #expect(store.revisions[1].nodeCount == 0)
    }

    @Test("counts describe the graph a person asked about")
    internal func countsAreReadOffTheSnapshot() throws {
        let store = CronGraphRevisionStore(testing: true)
        let revision = try #require(store.observe(base, at: epoch))

        // Two nodes, but one job: "how big is this graph" means jobs.
        #expect(revision.jobCount == 1)
        #expect(revision.nodeCount == 2)
        #expect(revision.edgeCount == 1)
        #expect(revision.shortDigest == CronGraphDigest.over(base).short)
    }

    // MARK: - Trimming

    @Test("the log trims the oldest entries and leaves the truncation visible")
    internal func trimDropsOldestAndDanglesTheChain() throws {
        let store = CronGraphRevisionStore(testing: true)
        for index in 0..<260 {
            let graph = CronGraph(
                nodes: [node(id: "abc123", schedule: "every \(index)m")],
                edges: []
            )
            store.observe(graph, at: epoch.addingTimeInterval(Double(index)))
        }

        #expect(store.revisions.count == 200)
        // The newest survived; the oldest went.
        #expect(store.latest?.observedAt == epoch.addingTimeInterval(259))
        #expect(store.revisions[0].observedAt == epoch.addingTimeInterval(60))
        // The new oldest entry still points at a parent that is no longer here.
        // That dangle is the truth — the chain is cut, not started — so a reader
        // walking parents stops at a digest it can't find rather than being told
        // the graph began there.
        let oldestParent = try #require(store.revisions[0].parentDigest)
        #expect(!store.revisions.contains { $0.digest == oldestParent })
    }

    // MARK: - Persistence shape

    @Test("a revision survives a JSON round trip")
    internal func revisionsRoundTripThroughJSON() throws {
        // The log is only useful across launches, so the snapshot has to encode.
        // `CronGraph`'s `Codable` exists for this and nothing else — the gateway
        // path is `decodeGatewayValue`.
        let store = CronGraphRevisionStore(testing: true)
        store.observe(base, at: epoch)
        store.observe(rescheduled, at: epoch.addingTimeInterval(60))

        let data = try JSONEncoder().encode(store.revisions)
        let decoded = try JSONDecoder().decode([CronGraphRevision].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded.map(\.digest) == store.revisions.map(\.digest))
        #expect(decoded.map(\.parentDigest) == store.revisions.map(\.parentDigest))
        #expect(decoded.map(\.id) == store.revisions.map(\.id))
        #expect(decoded[1].graph == store.revisions[1].graph)
        #expect(abs(decoded[0].observedAt.timeIntervalSince(epoch)) < 0.001)
        // A decoded snapshot still verifies against its own commitment.
        #expect(CronGraphDigest.over(decoded[1].graph).hex == decoded[1].digest)
    }

    // MARK: - How the log describes itself

    @Test("the log calls itself observation, not authorship")
    internal func summaryDisclaimsAuthorship() {
        // The count on its own reads as "the dataflow changed N times". It didn't
        // necessarily: N is how many distinct commitments this app saw while
        // polling. If the surface doesn't say that, it's a log that lies.
        let store = CronGraphRevisionStore(testing: true)
        #expect(store.observationSummary(now: epoch).contains("No revisions on record yet"))

        store.observe(base, at: epoch)
        let single = store.observationSummary(now: epoch.addingTimeInterval(3600))
        #expect(single.contains("1 revision "))
        #expect(single.contains("observed"))
        #expect(single.contains("not when it was made"))

        store.observe(rescheduled, at: epoch.addingTimeInterval(60))
        #expect(store.observationSummary(now: epoch.addingTimeInterval(3600)).contains("2 revisions"))
    }
}

/// The view model's end of the log: which code paths count as an observation.
@MainActor
@Suite("Cron graph revision log — view model")
internal struct CronGraphRevisionViewModelTests {

    @Test("seeding a graph in a test is not an observation")
    internal func testSeedingDoesNotRecord() {
        // `setGraphForTesting` bypasses `adopt` on purpose: a test constructing a
        // graph is not Portal noticing one, and if it recorded, every other test
        // touching the graph VM would quietly write history.
        let store = CronGraphRevisionStore(testing: true)
        let vm = CronGraphViewModel(revisionStore: store)
        vm.setGraphForTesting(CronGraph(
            nodes: [CronGraphNode(id: "abc123", kind: "cron", type: "cron", label: "indexing/sweep",
                                  description: "", schedule: "every 60m", enabled: true,
                                  usesLLM: false, lastStatus: "ok", deliver: nil)],
            edges: []
        ))

        #expect(store.revisions.isEmpty)
        #expect(vm.digest != CronGraphDigest.emptyGraph)
        #expect(vm.revisionLogSummary.contains("No revisions on record yet"))
    }
}
