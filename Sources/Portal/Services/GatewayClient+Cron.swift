import Foundation

// MARK: - Cron interflow graph RPC

@MainActor
extension GatewayClient {

    /// Fetch the cron interflow dataflow graph (`cron.graph`): every scheduled
    /// job plus the external sources it reads, the artifacts it writes, and the
    /// side-effect sinks it drives — with typed edges between them.
    ///
    /// Crons never call each other; they communicate through data (one writes
    /// an artifact, a later cron wakes and reads it). So cron → cron edges are
    /// *inferred* — from a shared data ref or an explicit `cron-output:<id>`
    /// input — making this a dataflow graph, not a call graph. Same edge shape
    /// as `wiki.scan` so the graph renderer is shared.
    internal func cronGraph() async throws -> CronGraph {
        // One un-paginated round-trip; a ceiling keeps a wedged gateway from
        // pinning the pane on "Loading…" forever (mirrors wiki.scan).
        let response = try await call("cron.graph", params: [:], timeout: 30)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("cron.graph missing nodes/edges arrays")
        }
        return try CronGraph.decodeGatewayValue(result)
    }
}
