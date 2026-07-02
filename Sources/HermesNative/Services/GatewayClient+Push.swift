import Foundation

// MARK: - Push (APNs) RPCs

/// Result of `push.register` — includes whether the gateway has APNs
/// credentials configured (APNS_* env vars), so the client can surface
/// "remote push inactive" state instead of failing silently.
struct PushRegisterResult {
    let registered: Bool
    let apnsConfigured: Bool
}

@MainActor
extension GatewayClient {

    /// Register this device's APNs token with the gateway so it can push
    /// notifications (approvals, turn completions, cron results) even when
    /// the app is closed. See hermes-agent docs/api/apns-push.md.
    func registerPushToken(
        token: String,
        platform: String,
        deviceName: String,
        bundleID: String
    ) async throws -> PushRegisterResult {
        var params: [String: AnyCodable] = [
            "token": AnyCodable(token),
            "platform": AnyCodable(platform),
        ]
        if !deviceName.isEmpty { params["device_name"] = AnyCodable(deviceName) }
        if !bundleID.isEmpty { params["bundle_id"] = AnyCodable(bundleID) }

        let response = try await call("push.register", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let dict = response.result?.dictionaryValue
        return PushRegisterResult(
            registered: dict?["registered"]?.boolValue ?? false,
            apnsConfigured: dict?["apns_configured"]?.boolValue ?? false
        )
    }

    /// Remove this device's token from the gateway (e.g. on sign-out).
    func unregisterPushToken(token: String) async throws -> Bool {
        let response = try await call("push.unregister", params: ["token": AnyCodable(token)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["removed"]?.boolValue ?? false
    }
}
