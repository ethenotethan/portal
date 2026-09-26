import Foundation

// MARK: - Service log capture RPC (service.logs / service.logs.follow)

/// Log sinks belong to the runtime side of the standard, so the methods live
/// under `service.*` and take the graph service id (`arch:<id>` today, a
/// `launchd:<label>` node later). Providers without log capture answer 4042
/// ("log capture is not implemented for this provider yet"); the Logs tab shows
/// that message verbatim.
@MainActor
extension GatewayClient {

    /// The tail of a declared log sink (`service.logs`): the last `lines`
    /// lines without a cursor, or every complete line appended since `cursor`.
    internal func serviceLogs(service: String, sink: String?, lines: Int, cursor: String?) async throws -> ArchitectureLogTail {
        var params: [String: AnyCodable] = ["service": .string(service), "lines": .int(lines)]
        if let sink, !sink.isEmpty { params["sink"] = .string(sink) }
        if let cursor, !cursor.isEmpty { params["cursor"] = .string(cursor) }
        let response = try await call("service.logs", params: params, timeout: 60)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("service.logs returned no result")
        }
        return try ArchitectureLogTail.decodeGatewayValue(result)
    }

    /// Start or stop following a sink (`service.logs.follow`); new lines
    /// then arrive as `service.log` events.
    internal func serviceLogsFollow(service: String, sink: String?, enabled: Bool) async throws -> ArchitectureLogFollowState {
        var params: [String: AnyCodable] = ["service": .string(service), "enabled": .bool(enabled)]
        if let sink, !sink.isEmpty { params["sink"] = .string(sink) }
        let response = try await call("service.logs.follow", params: params, timeout: 30)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("service.logs.follow returned no result")
        }
        return try ArchitectureLogFollowState.decodeGatewayValue(result)
    }
}
