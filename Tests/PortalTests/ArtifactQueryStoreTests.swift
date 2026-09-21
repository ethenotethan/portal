import Combine
import Foundation
import Testing
@testable import Portal

// The query slot state machine in ArtifactStore, driven against a scriptable
// gateway: local validation before any round trip, subscribe-then-invoke for
// live queries, conflict refresh-and-retry, gateway change events, intent
// invalidation, and release. No WebView, no socket.

@MainActor
private final class FakeQueryGateway: ArtifactGateway {
    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    var invokeResult: ArtifactQueryResult?
    var subscribeResult: ArtifactQueryResult?
    var invokeError: Error?
    /// Returned by artifactGet — what a conflict retry re-reads.
    var refreshed: LivingArtifact?
    /// Returned by artifactList — used to exercise the cold-cache pull path.
    var listed: [LivingArtifact]?

    private(set) var invokeCalls: [(rev: Int, queryID: String, params: [String: AnyCodable])] = []
    private(set) var subscribeCalls: [(rev: Int, queryID: String, params: [String: AnyCodable])] = []
    private(set) var unsubscribed: [String] = []

    func artifactQueryInvoke(
        artifactID: String, artifactRev: Int, queryID: String,
        params: [String: AnyCodable], cursor: String?
    ) async throws -> ArtifactQueryResult? {
        invokeCalls.append((artifactRev, queryID, params))
        if let invokeError { throw invokeError }
        return invokeResult
    }

    func artifactQuerySubscribe(
        artifactID: String, artifactRev: Int, queryID: String,
        params: [String: AnyCodable]
    ) async throws -> ArtifactQueryResult? {
        subscribeCalls.append((artifactRev, queryID, params))
        return subscribeResult
    }

    func artifactQueryUnsubscribe(handle: String) async throws { unsubscribed.append(handle) }

    func artifactActionInvoke(
        artifactID: String, artifactRev: Int, bindingID: String,
        entityRef: String, idempotencyKey: String
    ) async throws -> ArtifactActionInvokeResult? {
        .init(outcome: .succeeded(message: nil, sessionID: nil))
    }
    func artifactActionConfirm(artifactID: String, challenge: String) async throws -> ArtifactActionInvokeResult? { nil }
    func artifactActionLog(artifactID: String, bindingID: String?, limit: Int) async throws -> [[String: AnyCodable]]? { nil }
    func artifactGet(id: String) async throws -> LivingArtifact? { refreshed }
    func artifactList() async throws -> [LivingArtifact]? { listed }
    func artifactSet(id: String, kind: String, content: String, title: String?, replace: Bool) async throws -> LivingArtifact? { nil }
    func artifactDelete(id: String) async throws {}
}

@Suite("Artifact query slots")
@MainActor
private struct ArtifactQueryStoreTests {

    private static let queries = ArtifactQuery.parse([
        [
            "id": "rows", "query": "artifact.rows",
            "bind": ["source": "orders"],
            "params": ["limit": ["type": "int", "min": 1, "max": 50, "default": 10]],
            "live": ["mode": "poll", "interval_s": 5],
            "invalidated_by": ["archive-order"],
        ],
        ["id": "once", "query": "artifact.rows", "params": [:]],
    ])

    private func makeStore(rev: Int = 3) -> (ArtifactStore, FakeQueryGateway) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-query-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        store.seedArtifactForTesting(LivingArtifact(
            id: "dash", kind: "html", title: "Dash", content: "<html/>",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: rev,
            queries: Self.queries))
        let fake = FakeQueryGateway()
        store.injectClientForTesting(fake)
        return (store, fake)
    }

    private func slot(_ queryID: String = "rows", _ rawParams: String = "") -> ArtifactStore.QuerySlot {
        ArtifactStore.QuerySlot(artifactID: "dash", queryID: queryID, rawParams: rawParams)
    }

    private func okResult(_ etag: String, subscription: String? = nil) -> ArtifactQueryResult {
        ArtifactQueryResult(
            outcome: .ok(data: .dictionary(["rows": .array([.dictionary(["id": .string("o1")])])]), etag: etag, nextCursor: nil),
            subscription: subscription)
    }

    @Test("pull restores query manifests omitted from an equal-revision disk cache")
    internal func pullRestoresQueriesAtEqualRevision() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-query-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("artifacts.json")
        let remote = LivingArtifact(
            id: "dash", kind: "html", title: "Dash", content: "<html/>",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: 9,
            queries: Self.queries)

        // LivingArtifact intentionally excludes manifests from Codable. This
        // reproduces a real app restart with an otherwise-current rev-9 cache.
        try JSONEncoder().encode([remote.id: remote]).write(to: fileURL)
        let store = ArtifactStore(fileURL: fileURL)
        #expect(store.artifacts[remote.id]?.queries.isEmpty == true)

        let fake = FakeQueryGateway()
        fake.listed = [remote]
        store.injectClientForTesting(fake)
        await store.pull()

        #expect(store.artifacts[remote.id]?.queries.map(\.id) == ["rows", "once"])
    }

    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<10_000 where !predicate() { await Task.yield() }
    }

    /// True once a slot has an answer — not absent, not still loading.
    private func finished(_ store: ArtifactStore, _ slot: ArtifactStore.QuerySlot) -> Bool {
        guard let state = store.queryStates[slot] else { return false }
        return state != .loading
    }

    @Test("a live query subscribes first and lands its data as sink text")
    internal func liveQuerySubscribes() async {
        let (store, fake) = makeStore()
        fake.subscribeResult = okResult("e1", subscription: "dash/rows/h")

        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "{\"limit\": 5}")
        await settle { self.finished(store, self.slot("rows", "{\"limit\": 5}")) }

        #expect(fake.subscribeCalls.count == 1)
        #expect(fake.invokeCalls.isEmpty)
        // Pinned to the rendered revision; bound source travels; page limit coerced.
        #expect(fake.subscribeCalls[0].rev == 3)
        #expect(fake.subscribeCalls[0].params == ["source": .string("orders"), "limit": .int(5)])
        #expect(store.queryStates[slot("rows", "{\"limit\": 5}")]
                == .ok(payload: "{\"rows\":[{\"id\":\"o1\"}]}", etag: "e1"))
    }

    @Test("a one-shot query invokes, never subscribes")
    internal func oneShotInvokes() async {
        let (store, fake) = makeStore()
        fake.invokeResult = okResult("e1")
        store.runQuery(artifactID: "dash", queryID: "once", rawParams: "")
        await settle { self.finished(store, self.slot("once")) }
        #expect(fake.invokeCalls.count == 1)
        #expect(fake.subscribeCalls.isEmpty)
    }

    @Test("bad parameters are refused before any round trip")
    internal func localValidationFirst() async {
        let (store, fake) = makeStore()
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "{\"limit\": 500}")
        await settle { store.queryStates[self.slot("rows", "{\"limit\": 500}")] != nil }
        #expect(store.queryStates[slot("rows", "{\"limit\": 500}")]
                == .failed(reason: "parameter limit above maximum 50"))
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "[1]")
        await settle { store.queryStates[self.slot("rows", "[1]")] != nil }
        #expect(store.queryStates[slot("rows", "[1]")] == .failed(reason: "data-hermes-params is not a JSON object"))
        store.runQuery(artifactID: "dash", queryID: "ghost", rawParams: "")
        await settle { store.queryStates[self.slot("ghost")] != nil }
        #expect(store.queryStates[slot("ghost")] == .unsupported(reason: "The artifact declares no query ghost."))
        #expect(fake.subscribeCalls.isEmpty && fake.invokeCalls.isEmpty)
    }

    @Test("a conflict re-reads the artifact and retries once with its revision")
    internal func conflictRetriesOnce() async {
        let (store, fake) = makeStore(rev: 3)
        fake.invokeResult = ArtifactQueryResult(outcome: .conflict, subscription: nil)
        fake.refreshed = LivingArtifact(
            id: "dash", kind: "html", title: "Dash", content: "<html>v2</html>",
            updatedAt: Date(), updatedBy: "agent", rev: 7, queries: Self.queries)

        store.runQuery(artifactID: "dash", queryID: "once", rawParams: "")
        await settle { fake.invokeCalls.count == 2 }
        await settle { self.finished(store, self.slot("once")) }
        #expect(fake.invokeCalls.map(\.rev) == [3, 7])
        #expect(store.artifacts["dash"]?.rev == 7)
        // Still conflicting after the retry: report, don't loop.
        #expect(store.queryStates[slot("once")] == .failed(reason: "The artifact changed while the query ran."))
    }

    @Test("a change event re-runs the slot through invoke, keeping the subscription")
    internal func changeEventReruns() async {
        let (store, fake) = makeStore()
        fake.subscribeResult = okResult("e1", subscription: "h1")
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "")
        await settle { fake.subscribeCalls.count == 1 && self.finished(store, self.slot()) }

        fake.invokeResult = okResult("e2")
        store.applyGatewayEventForTesting(
            .artifactQueryChanged(artifactID: "dash", queryID: "rows", status: "ok", reason: ""))
        await settle { fake.invokeCalls.count == 1 }
        await settle { store.queryStates[self.slot()] == .ok(payload: "{\"rows\":[{\"id\":\"o1\"}]}", etag: "e2") }
        #expect(fake.subscribeCalls.count == 1)

        // The gateway dropped the slot: the page hears why, and nothing re-runs.
        store.applyGatewayEventForTesting(.artifactQueryChanged(
            artifactID: "dash", queryID: "rows", status: "unsupported", reason: "handler unloaded"))
        await settle { store.queryStates[self.slot()] == .unsupported(reason: "handler unloaded") }
        #expect(fake.invokeCalls.count == 1)
    }

    @Test("a succeeded intent invalidates the queries that named it")
    internal func intentInvalidates() async {
        let (store, fake) = makeStore()
        fake.subscribeResult = okResult("e1", subscription: "h1")
        fake.invokeResult = okResult("e1")
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "")
        store.runQuery(artifactID: "dash", queryID: "once", rawParams: "")
        await settle { self.finished(store, self.slot()) && self.finished(store, self.slot("once")) }
        let invokesBefore = fake.invokeCalls.count

        await store.invokeIntent(artifactID: "dash", bindingID: "archive-order", entryKey: "o1")
        await settle { fake.invokeCalls.count == invokesBefore + 1 }
        // Only `rows` declared invalidated_by: archive-order; `once` did not.
        #expect(fake.invokeCalls.last?.queryID == "rows")
    }

    @Test("releasing an artifact unsubscribes and forgets its slots")
    internal func releaseUnsubscribes() async {
        let (store, fake) = makeStore()
        fake.subscribeResult = okResult("e1", subscription: "dash/rows/h")
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "")
        await settle { self.finished(store, self.slot()) }

        store.releaseQueries(artifactID: "dash")
        await settle { fake.unsubscribed == ["dash/rows/h"] }
        #expect(store.querySlots(artifactID: "dash").isEmpty)
    }

    @Test("a gateway without the surface, or a failing call, says so on the slot")
    internal func gatewayGapsAreReported() async {
        let (store, fake) = makeStore()
        fake.invokeResult = nil
        store.runQuery(artifactID: "dash", queryID: "once", rawParams: "")
        await settle { self.finished(store, self.slot("once")) }
        #expect(store.queryStates[slot("once")]
                == .unsupported(reason: "This gateway has no artifact.query surface — it's too old for queries."))

        fake.invokeError = URLError(.notConnectedToInternet)
        store.runQuery(artifactID: "dash", queryID: "once", rawParams: "{}")
        await settle { self.finished(store, self.slot("once", "{}")) }
        guard case .failed = store.queryStates[slot("once", "{}")] else {
            Issue.record("expected failed, got \(String(describing: store.queryStates[slot("once", "{}")]))")
            return
        }
    }

    @Test("gateway.ready after a drop re-subscribes live slots and keeps the last payload on screen")
    internal func gatewayReadyResubscribesLiveSlots() async {
        let (store, fake) = makeStore()
        fake.subscribeResult = okResult("e1", subscription: "dash/rows/h1")
        store.runQuery(artifactID: "dash", queryID: "rows", rawParams: "")
        await settle { self.finished(store, self.slot()) }
        #expect(fake.subscribeCalls.count == 1)

        // Watch for an empty flash: the slot must never fall back to .loading.
        final class Seen { var loadingAfterOK = false }
        let seen = Seen()
        let watcher = store.$queryStates.sink { states in
            if states[self.slot()] == .loading { seen.loadingAfterOK = true }
        }
        defer { watcher.cancel() }

        // The gateway restarted and forgot the subscription; the socket came back.
        fake.subscribeResult = okResult("e2", subscription: "dash/rows/h2")
        store.applyGatewayEventForTesting(.gatewayReady(skin: "default"))
        await settle { fake.subscribeCalls.count == 2 && fake.unsubscribed.contains("dash/rows/h1") }

        #expect(fake.subscribeCalls.count == 2, "a fresh subscribe, not a plain invoke against a dead handle")
        #expect(fake.invokeCalls.isEmpty)
        #expect(fake.unsubscribed == ["dash/rows/h1"], "the stale handle is released best-effort")
        #expect(!seen.loadingAfterOK, "last-known-good data stays on screen through the reconnect")
        guard case .ok(_, let etag)? = store.queryStates[slot()] else {
            Issue.record("slot not ok")
            return
        }
        #expect(etag == "e2")

        // Release unsubscribes the new handle only.
        store.releaseQueries(artifactID: "dash")
        await settle { fake.unsubscribed.count == 2 }
        #expect(fake.unsubscribed == ["dash/rows/h1", "dash/rows/h2"])
    }

    @Test("gateway.ready with no live handles (first connect) does nothing")
    internal func gatewayReadyWithoutHandlesIsNoop() async {
        let (store, fake) = makeStore()
        store.applyGatewayEventForTesting(.gatewayReady(skin: "default"))
        await settle { false }
        #expect(fake.subscribeCalls.isEmpty && fake.invokeCalls.isEmpty && fake.unsubscribed.isEmpty)
        #expect(store.queryStates.isEmpty)
    }
}
