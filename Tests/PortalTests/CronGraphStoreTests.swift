import Foundation
import Testing
@testable import Portal

@MainActor
@Suite("Cron graph store")
internal struct CronGraphStoreTests {
    private final class StubSource: CronGraphFetching {
        let result: CronGraph

        init(result: CronGraph) {
            self.result = result
        }

        func cronGraph() async throws -> CronGraph { result }
    }

    private func graph(status: String? = nil) -> CronGraph {
        CronGraph(
            nodes: [
                CronGraphNode(
                    id: "job", kind: "cron", type: "cron", label: "job", description: "",
                    schedule: "every 1h", enabled: true, usesLLM: false,
                    lastStatus: status, deliver: nil
                ),
            ],
            edges: []
        )
    }

    @Test("startup restores the latest locally persisted graph before a network fetch")
    internal func startupRestoresLatestGraph() throws {
        let revisions = CronGraphRevisionStore(testing: true)
        let cached = graph(status: "ok")
        _ = revisions.observe(cached, at: Date(timeIntervalSince1970: 1))

        let store = CronGraphStore(revisionStore: revisions)

        #expect(store.graph == CronGraphDigest.configuration(of: cached))
    }

    @Test("poll refresh publishes current runtime state without inventing a configuration revision")
    internal func refreshPublishesRuntimeState() async throws {
        let revisions = CronGraphRevisionStore(testing: true)
        _ = revisions.observe(graph(status: "ok"), at: Date(timeIntervalSince1970: 1))
        let store = CronGraphStore(revisionStore: revisions)

        try await store.refresh(from: StubSource(result: graph(status: "error")))

        #expect(store.graph.nodes.first?.lastStatus == "error")
        #expect(revisions.revisions.count == 1)
    }

    @Test("a graph view model renders the store's cached graph without fetching on appearance")
    internal func viewModelRendersCachedGraph() throws {
        let revisions = CronGraphRevisionStore(testing: true)
        _ = revisions.observe(graph(status: "ok"), at: Date(timeIntervalSince1970: 1))
        let store = CronGraphStore(revisionStore: revisions)

        let viewModel = CronGraphViewModel(graphStore: store, revisionStore: revisions)

        #expect(viewModel.graph.nodes.map(\.id) == ["job"])
        #expect(viewModel.simNodes.map(\.id) == ["job"])
        #expect(!viewModel.isLoading)
    }

    @Test("the app poller refreshes the graph store without a graph surface being open")
    internal func pollerRefreshesGraphStore() async {
        let revisions = CronGraphRevisionStore(testing: true)
        let store = CronGraphStore(revisionStore: revisions)
        let poller = CronPoller(graphStore: store)

        await poller.pollGraph(from: StubSource(result: graph(status: "ok")))

        #expect(store.graph.nodes.map(\.id) == ["job"])
        #expect(revisions.revisions.count == 1)
    }
}
