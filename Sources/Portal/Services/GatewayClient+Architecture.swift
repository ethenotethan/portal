import Foundation

// MARK: - Per-service architecture models RPC

@MainActor
extension GatewayClient {

    /// Fetch a service's architecture model (`architecture.describe`): the
    /// compiler-emitted model the service's manifest points at, read at its
    /// current revision (and snapshotted by the gateway) or, with `revision`, a
    /// stored snapshot. The model is kept as JSON for the observatory renderer.
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
}

extension GatewayClient: ArchitectureReading {}
