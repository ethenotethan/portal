import Foundation
import Combine

// MARK: - Per-service architecture models RPC

@MainActor
extension GatewayClient {

    /// Fetch a service's architecture model (`architecture.describe`): the
    /// compiler-emitted model the service's manifest points at, read at its
    /// current revision (and snapshotted by the gateway) or, with `revision`, a
    /// stored snapshot, decoded for the native section renderers.
    internal func architectureDescribe(service: String, revision: String? = nil) async throws -> ArchitectureModelDocument {
        var params: [String: AnyCodable] = ["service": .string(service)]
        if let revision, !revision.isEmpty {
            params["revision"] = .string(revision)
        }
        let response = try await call("architecture.describe", params: params, timeout: 60)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("architecture.describe returned no result")
        }
        return try ArchitectureModelDocument.decodeGatewayValue(result)
    }

    /// Run a local service's own `--check` in its root (`architecture.check`).
    /// Bounded at five minutes on the gateway; the timeout here leaves room.
    internal func architectureCheck(service: String) async throws -> ArchitectureCheckResult {
        let response = try await call("architecture.check", params: ["service": .string(service)], timeout: 330)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let checkValue = result["check"],
              let check = ArchitectureCheckResult.decodeGatewayValue(checkValue) else {
            throw GatewayError.invalidResponse("architecture.check returned no check result")
        }
        return check
    }

    /// The tail of a declared log sink (`architecture.logs`): the last `lines`
    /// lines without a cursor, or every complete line appended since `cursor`.
    internal func architectureLogs(service: String, sink: String?, lines: Int, cursor: String?) async throws -> ArchitectureLogTail {
        var params: [String: AnyCodable] = ["service": .string(service), "lines": .int(lines)]
        if let sink, !sink.isEmpty { params["sink"] = .string(sink) }
        if let cursor, !cursor.isEmpty { params["cursor"] = .string(cursor) }
        let response = try await call("architecture.logs", params: params, timeout: 60)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("architecture.logs returned no result")
        }
        return try ArchitectureLogTail.decodeGatewayValue(result)
    }

    /// Start or stop following a sink (`architecture.logs.follow`); new lines
    /// then arrive as `architecture.log` events.
    internal func architectureLogsFollow(service: String, sink: String?, enabled: Bool) async throws -> ArchitectureLogFollowState {
        var params: [String: AnyCodable] = ["service": .string(service), "enabled": .bool(enabled)]
        if let sink, !sink.isEmpty { params["sink"] = .string(sink) }
        let response = try await call("architecture.logs.follow", params: params, timeout: 30)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("architecture.logs.follow returned no result")
        }
        return try ArchitectureLogFollowState.decodeGatewayValue(result)
    }

    /// Every stored revision of a service's model (`architecture.history`),
    /// with the commits behind them for a local checkout.
    internal func architectureHistory(service: String, limit: Int?) async throws -> ArchitectureRevisionHistory {
        var params: [String: AnyCodable] = ["service": .string(service)]
        if let limit, limit > 0 { params["limit"] = .int(limit) }
        let response = try await call("architecture.history", params: params, timeout: 60)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("architecture.history returned no result")
        }
        return try ArchitectureRevisionHistory.decodeGatewayValue(result)
    }

    /// The structural diff between two stored revisions (`architecture.diff`);
    /// `to` defaults to the latest and `from` to the one before it.
    internal func architectureDiff(service: String, from: String?, to: String?) async throws -> ArchitectureRevisionDiff {
        var params: [String: AnyCodable] = ["service": .string(service)]
        if let from, !from.isEmpty { params["from"] = .string(from) }
        if let to, !to.isEmpty { params["to"] = .string(to) }
        let response = try await call("architecture.diff", params: params, timeout: 120)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("architecture.diff returned no result")
        }
        return try ArchitectureRevisionDiff.decodeGatewayValue(result)
    }

    /// The gateway's event stream without its session tag, for surfaces that
    /// follow global events such as `architecture.log`.
    internal var architectureEvents: AnyPublisher<GatewayEvent, Never> {
        eventStream.map(\.0).eraseToAnyPublisher()
    }
}

extension GatewayClient: ArchitectureReading {}
