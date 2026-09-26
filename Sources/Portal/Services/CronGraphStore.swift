import Combine

@MainActor
internal protocol CronGraphFetching: AnyObject {
    func cronGraph() async throws -> CronGraph
}

extension GatewayClient: CronGraphFetching {}

/// App-scoped source of truth for the cron interflow graph.
///
/// The latest observed revision seeds `graph` synchronously, so graph surfaces
/// can render local state before the gateway responds. Network refreshes update
/// this store rather than making each surface fetch its own copy.
@MainActor
internal final class CronGraphStore: ObservableObject {
    @Published internal private(set) var graph: CronGraph

    private let revisionStore: CronGraphRevisionStore

    internal init(revisionStore: CronGraphRevisionStore = .shared) {
        self.revisionStore = revisionStore
        graph = revisionStore.latest?.graph ?? .empty
    }

    /// Fetch the current graph once, publish it to every surface, and append a
    /// durable observation only when its configuration commitment changed.
    internal func refresh(from source: any CronGraphFetching) async throws {
        let fetched = try await source.cronGraph()
        revisionStore.observe(fetched)
        graph = fetched
    }
}
