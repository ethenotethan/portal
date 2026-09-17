import Foundation

// MARK: - Per-service code knowledge graph RPC

@MainActor
extension GatewayClient {

    /// Fetch the code knowledge graph for one `service` node (`code.graph`): the
    /// module/class/function nodes and typed import/call/structure edges the
    /// gateway extracts from the service's declared `source_files`, clustered
    /// into communities.
    ///
    /// The gateway builds this on demand and caches it keyed on a content digest
    /// of those files, so the graph tracks the current service definition without
    /// a changeset trigger. Same typed-edge shape as `cron.graph`/`wiki.scan`, so
    /// `CodeGraphSource` can adapt it onto the shared wiki graph renderer.
    internal func codeGraph(service: String) async throws -> CodeGraph {
        let response = try await call(
            "code.graph",
            params: ["service": AnyCodable(service)],
            timeout: 30
        )
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("code.graph missing nodes/edges arrays")
        }
        return try CodeGraph.decodeGatewayValue(result)
    }
}
