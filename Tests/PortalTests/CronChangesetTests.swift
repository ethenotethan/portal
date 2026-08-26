import Foundation
import Testing
@testable import Portal

// MARK: - Fixtures

/// Payloads shaped like the `cron.changesets` response in #384 layer 3: a
/// populated row, and the sparse row a gateway that records less would send.
private enum Fixtures {

    static let full: AnyCodable = .dictionary([
        "id": AnyCodable("cs-42"),
        "timestamp": AnyCodable("2026-08-20T15:00:00Z"),
        "action": AnyCodable("update"),
        "job": AnyCodable("indexing/solana sweep"),
        "digest": AnyCodable("a3f91cbe4d5069f8a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718"),
        "parent_digest": AnyCodable("bb00112233445566778899aabbccddeeff00112233445566778899aabbccddee"),
        "actor": AnyCodable("agent"),
        "summary": AnyCodable("rewired the sweep to read x402"),
        "source_event_keys": .array([AnyCodable("session/abc123/turn-7"), AnyCodable("  ")]),
        "git_commit": AnyCodable("9f2c1ab"),
    ])

    /// Everything optional omitted: no actor, no provenance, no parent, no time.
    static let bare: AnyCodable = .dictionary([
        "id": AnyCodable("cs-1"),
        "digest": AnyCodable("cc00112233445566778899aabbccddeeff00112233445566778899aabbccddee"),
        "parent_digest": AnyCodable(""),
    ])

    static let page: AnyCodable = .dictionary([
        "changesets": .array([full, bare, .dictionary(["timestamp": AnyCodable("2026-08-20T16:00:00Z")])]),
        "total": AnyCodable(97),
        "limit": AnyCodable(2),
        "offset": AnyCodable(0),
    ])
}

// MARK: - Decoding

@Suite("cron.changesets decoding")
internal struct CronChangesetDecodingTests {

    @Test("a populated row decodes every recorded field")
    internal func decodesFullRow() throws {
        let changeset = try #require(GatewayClient.cronChangeset(from: Fixtures.full))
        #expect(changeset.id == "cs-42")
        #expect(changeset.action == "update")
        #expect(changeset.job == "indexing/solana sweep")
        #expect(changeset.actor == .agent)
        #expect(changeset.summary == "rewired the sweep to read x402")
        #expect(changeset.gitCommit == "9f2c1ab")
        #expect(changeset.parentDigest?.hasPrefix("bb0011") == true)
        // Blank provenance entries are dropped, not turned into a ref pointing
        // at nothing.
        #expect(changeset.provenance == .turns([CronTurnRef(key: "session/abc123/turn-7")]))
        #expect(changeset.date == ISO8601DateFormatter().date(from: "2026-08-20T15:00:00Z"))
    }

    @Test("a digest from the gateway shortens to the same width as a locally computed one")
    internal func shortDigestMatchesTheChipWidth() throws {
        // Otherwise the same commitment reads as two different strings depending
        // on which source reported it, and the chip stops being comparable.
        let changeset = try #require(GatewayClient.cronChangeset(from: Fixtures.full))
        #expect(changeset.shortDigest.count == CronGraphDigest.shortLength)
        #expect(changeset.shortDigest == String(changeset.digest.prefix(CronGraphDigest.shortLength)))
    }

    @Test("a sparse row still decodes, and records nothing it wasn't told")
    internal func decodesBareRow() throws {
        let changeset = try #require(GatewayClient.cronChangeset(from: Fixtures.bare))
        #expect(changeset.id == "cs-1")
        // An empty parent digest has to arrive as nil: "" would later be compared
        // against a real digest and chain this change to a revision that isn't
        // there.
        #expect(changeset.parentDigest == nil)
        #expect(changeset.actor == .unknown)
        #expect(changeset.provenance == .unknown)
        #expect(changeset.date == nil)
        #expect(changeset.action.isEmpty)
    }

    @Test("a row with no id is dropped rather than invented")
    internal func rowsWithoutIdentityAreDropped() {
        #expect(GatewayClient.cronChangeset(from: .dictionary(["action": AnyCodable("update")])) == nil)
        let page = GatewayClient.cronChangesetsPage(from: Fixtures.page, requestedLimit: 2, requestedOffset: 0)
        #expect(page.changesets.map(\.id) == ["cs-42", "cs-1"])
        // The cursor is the server's, and `hasMore` is counted from what arrived.
        #expect(page.total == 97)
        #expect(page.hasMore)
    }

    @Test("a response with no envelope fields falls back to what was asked for")
    internal func pageFallsBackToTheRequestedCursor() {
        let page = GatewayClient.cronChangesetsPage(
            from: .dictionary(["changesets": .array([Fixtures.bare])]),
            requestedLimit: 50, requestedOffset: 100
        )
        #expect(page.limit == 50)
        #expect(page.offset == 100)
        // Total unknown: reporting the count that arrived is the only claim
        // available, and it must not imply more pages exist.
        #expect(page.total == 1)
        #expect(!page.hasMore)
    }

    @Test("an actor value this app doesn't know survives to the screen")
    internal func unknownActorValuesArePreservedNotFlattened() {
        #expect(CronChangesetActor(raw: "human") == .human)
        #expect(CronChangesetActor(raw: "Agent") == .agent)
        #expect(CronChangesetActor(raw: "scheduler") == .scheduler)
        // Not guessed into `.human` — the word it sent is shown instead.
        #expect(CronChangesetActor(raw: "user") == .other("user"))
        #expect(CronChangesetActor(raw: "user").label == "user")
        // Nothing recorded is not a claim that nobody did it.
        #expect(CronChangesetActor(raw: "  ") == .unknown)
        #expect(CronChangesetActor(raw: "").isRecorded == false)
        #expect(CronChangesetActor(raw: "user").isRecorded)
    }

    @Test("provenance is unknown for absent, null, and empty alike")
    internal func provenanceCollapsesEveryEmptyShape() {
        #expect(CronChangesetProvenance.decode(nil) == .unknown)
        #expect(CronChangesetProvenance.decode([]) == .unknown)
        #expect(CronChangesetProvenance.decode(["", "   "]) == .unknown)
        #expect(CronChangesetProvenance.decode(["session/abc/turn-1"]).isRecorded)
        #expect(CronTurnRef(key: "session/abc/turn-1").shortLabel == "turn-1")
        // A long opaque key is truncated for the chip, not parsed.
        #expect(CronTurnRef(key: "3F2A9C1B-7D4E-4A0F-9B8C-1D2E3F4A5B6C").shortLabel.count == 13)
    }

    @Test("the diff payload decodes both graphs, and tolerates either being absent")
    internal func diffPayloadDecodes() throws {
        let graph: AnyCodable = .dictionary([
            "nodes": .array([.dictionary([
                "id": AnyCodable("abc123"), "kind": AnyCodable("cron"), "type": AnyCodable("cron"),
                "label": AnyCodable("indexing/sweep"),
            ])]),
            "edges": .array([]),
        ])
        let both = try GatewayClient.cronChangesetDiff(from: .dictionary([
            "before": graph, "after": graph, "diff": AnyCodable("--- a\n+++ b\n"),
        ]))
        #expect(both.before?.nodes.count == 1)
        #expect(both.after?.nodes.count == 1)
        #expect(both.unifiedText == "--- a\n+++ b\n")

        let afterOnly = try GatewayClient.cronChangesetDiff(from: .dictionary(["after": graph]))
        #expect(afterOnly.before == nil)
        // An empty text diff is no text diff — an empty scroll view claims the
        // gateway had files to diff and found them identical.
        #expect(afterOnly.unifiedText == nil)
    }

    @Test("a missing before is the empty graph only when nothing preceded the change")
    internal func structuralDiffRefusesToInventAHistory() throws {
        let after = CronGraph(
            nodes: [CronGraphNode(id: "abc123", kind: "cron", type: "cron", label: "indexing/sweep",
                                  description: "", schedule: "every 60m", enabled: true,
                                  usesLLM: false, lastStatus: nil, deliver: nil)],
            edges: []
        )
        let payload = CronChangesetDiff(before: nil, after: after)
        // No parent: everything in it genuinely was news.
        let first = try #require(payload.structural(parentDigest: nil))
        #expect(first.changes.map(\.summary) == ["indexing/sweep added"])
        // Had a parent the gateway didn't send: diffing against empty would
        // report a steady-state graph as freshly built.
        #expect(payload.structural(parentDigest: "bb0011") == nil)
        // No after at all: nothing to state.
        #expect(CronChangesetDiff(before: after, after: nil).structural(parentDigest: nil) == nil)
    }
}

// MARK: - The feed

/// A source under the test's control, which is the point of the capability
/// protocol: the recorded path is exercised without a gateway that has the RPCs.
@MainActor
private final class StubSource: CronChangesetSource {
    var page = CronChangesetsPage(changesets: [], total: 0, limit: 50, offset: 0)
    var pageError: (any Error)?
    var diff = CronChangesetDiff(before: nil, after: nil)
    var diffError: (any Error)?
    var pageCalls = 0
    var diffCalls = 0

    func cronChangesets(
        limit: Int, offset: Int, since: String?, until: String?, job: String?
    ) async throws -> CronChangesetsPage {
        pageCalls += 1
        if let pageError { throw pageError }
        return page
    }

    func cronChangesetDiff(id: String) async throws -> CronChangesetDiff {
        diffCalls += 1
        if let diffError { throw diffError }
        return diff
    }
}

@MainActor
@Suite("Cron changeset feed")
internal struct CronChangesetFeedTests {

    private func changeset(_ id: String, parentDigest: String? = "bb0011") -> CronChangeset {
        CronChangeset(id: id, timestamp: "2026-08-20T15:00:00Z", action: "update",
                      job: "indexing/sweep", digest: "a3f91c", parentDigest: parentDigest,
                      actor: .agent, summary: "", provenance: .unknown, gitCommit: "")
    }

    private func notFound(code: Int, message: String) -> GatewayError {
        .rpcError(JSONRPCError(code: code, message: message))
    }

    @Test("a gateway that answers gives recorded history")
    internal func recordedHistoryLoads() async {
        let source = StubSource()
        source.page = CronChangesetsPage(changesets: [changeset("cs-2"), changeset("cs-1")],
                                         total: 97, limit: 50, offset: 0)
        let feed = CronChangesetFeed()
        await feed.load(from: source)

        #expect(feed.availability == .recorded)
        #expect(feed.changesets.map(\.id) == ["cs-2", "cs-1"])
        #expect(feed.total == 97)
        #expect(feed.hasRecordedHistory)
        // Nothing to explain: the rows are what they appear to be.
        #expect(feed.fallbackNote == nil)
    }

    @Test("method-not-found means this gateway records no history, and the drawer says so")
    internal func methodNotFoundFallsBackToObservations() async {
        let source = StubSource()
        source.pageError = notFound(code: -32601, message: "Method not found")
        let feed = CronChangesetFeed()
        await feed.load(from: source)

        #expect(feed.availability == .unsupported)
        #expect(!feed.hasRecordedHistory)
        let note = feed.fallbackNote ?? ""
        #expect(note.contains("doesn't record"))
        #expect(note.contains("observations"))
    }

    @Test("a gateway reporting an unknown method in its message counts too")
    internal func unknownMethodMessagesAreRecognized() async {
        for message in ["Unknown method: cron.changesets", "no such method", "not implemented yet"] {
            let source = StubSource()
            source.pageError = notFound(code: -32000, message: message)
            let feed = CronChangesetFeed()
            await feed.load(from: source)
            #expect(feed.availability == .unsupported, "\(message) should read as unsupported")
        }
    }

    @Test("a failure that isn't method-not-found is never reported as no-history")
    internal func failuresAreNotEvidenceOfAbsence() async {
        // Claiming "your gateway doesn't record cron history" because a call
        // timed out is a claim about the backend made from a network error, and
        // it hides a log that exists.
        for error: any Error in [
            GatewayError.timedOut(method: "cron.changesets", seconds: 30),
            GatewayError.notConnected,
            GatewayError.invalidResponse("cron.changesets missing result"),
            GatewayError.rpcError(JSONRPCError(code: -32603, message: "internal error")),
        ] {
            let source = StubSource()
            source.pageError = error
            let feed = CronChangesetFeed()
            await feed.load(from: source)

            #expect(feed.availability != .unsupported)
            #expect(CronChangesetFeed.isUnsupported(error) == false)
            #expect(feed.fallbackNote?.contains("Couldn't read") == true)
        }
    }

    @Test("a failed refresh keeps the history it already has, and says it may be stale")
    internal func failedRefreshKeepsRows() async {
        let source = StubSource()
        source.page = CronChangesetsPage(changesets: [changeset("cs-1")], total: 1, limit: 50, offset: 0)
        let feed = CronChangesetFeed()
        await feed.load(from: source)

        source.pageError = GatewayError.timedOut(method: "cron.changesets", seconds: 30)
        await feed.load(from: source)

        #expect(feed.hasRecordedHistory)
        #expect(feed.changesets.map(\.id) == ["cs-1"])
        #expect(feed.fallbackNote?.contains("out of date") == true)
    }

    @Test("a gateway that loses the method drops the rows it can no longer vouch for")
    internal func unsupportedClearsStaleRows() async {
        let source = StubSource()
        source.page = CronChangesetsPage(changesets: [changeset("cs-1")], total: 1, limit: 50, offset: 0)
        let feed = CronChangesetFeed()
        await feed.load(from: source)
        #expect(feed.hasRecordedHistory)

        source.pageError = notFound(code: -32601, message: "Method not found")
        await feed.load(from: source)
        #expect(!feed.hasRecordedHistory)
        #expect(feed.diffs.isEmpty)
    }

    // MARK: - Diffs

    @Test("a row's diff is fetched once and kept")
    internal func diffIsFetchedOnceAndCached() async throws {
        let source = StubSource()
        let after = CronGraph(
            nodes: [CronGraphNode(id: "abc123", kind: "cron", type: "cron", label: "indexing/sweep",
                                  description: "", schedule: "every 6h", enabled: true,
                                  usesLLM: false, lastStatus: nil, deliver: nil)],
            edges: []
        )
        let before = CronGraph(
            nodes: [CronGraphNode(id: "abc123", kind: "cron", type: "cron", label: "indexing/sweep",
                                  description: "", schedule: "every 60m", enabled: true,
                                  usesLLM: false, lastStatus: nil, deliver: nil)],
            edges: []
        )
        source.diff = CronChangesetDiff(before: before, after: after)
        let row = changeset("cs-1")
        let feed = CronChangesetFeed()

        await feed.loadDiff(for: row, from: source)
        await feed.loadDiff(for: row, from: source)
        #expect(source.diffCalls == 1)

        guard case .ready(let recorded) = try #require(feed.diffState(for: row)) else {
            Issue.record("expected a ready diff")
            return
        }
        // The statements are this app's, derived from the two graphs — the same
        // sentences the observed log produces, so both sources read identically.
        #expect(recorded.statements?.changes.map(\.summary)
                == ["indexing/sweep runs every 6h (was every 60m)"])
    }

    @Test("a diff that failed is retried, not cached as broken")
    internal func failedDiffsAreRetryable() async throws {
        let source = StubSource()
        source.diffError = GatewayError.timedOut(method: "cron.changeset_diff", seconds: 30)
        let row = changeset("cs-1")
        let feed = CronChangesetFeed()

        await feed.loadDiff(for: row, from: source)
        guard case .failed = try #require(feed.diffState(for: row)) else {
            Issue.record("expected a failed diff state")
            return
        }

        source.diffError = nil
        source.diff = CronChangesetDiff(before: .empty, after: .empty)
        await feed.loadDiff(for: row, from: source)
        #expect(source.diffCalls == 2)
        guard case .ready = try #require(feed.diffState(for: row)) else {
            Issue.record("expected the retry to succeed")
            return
        }
    }

    @Test("a gateway that won't say what came before doesn't get a diff invented for it")
    internal func aMissingBeforeWithAParentHasNoStatements() async throws {
        let source = StubSource()
        source.diff = CronChangesetDiff(before: nil, after: .empty)
        // This row claims a parent, so "before = empty" would be a fabrication.
        let row = changeset("cs-1", parentDigest: "bb0011")
        let feed = CronChangesetFeed()

        await feed.loadDiff(for: row, from: source)
        guard case .ready(let recorded) = try #require(feed.diffState(for: row)) else {
            Issue.record("expected a ready diff")
            return
        }
        #expect(recorded.statements == nil)
    }
}
