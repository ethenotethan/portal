import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "PushRegistration")

/// Bridges APNs device-token registration to the gateway.
///
/// Flow: the app delegate calls `registerForRemoteNotifications()` at launch;
/// the OS calls back with a device token, which the delegate hands to
/// `store(deviceToken:)`. Whenever a gateway connection is (re)established,
/// ContentView calls `syncIfNeeded(client:)`, which sends `push.register` so
/// the CURRENT gateway knows this device — including after a gateway switch.
///
/// The gateway pushes via APNs only when its APNS_* env credentials are set;
/// its register response reports `apns_configured` so we can log the state.
@MainActor
final class PushRegistrationService: ObservableObject {
    static let shared = PushRegistrationService()

    /// Hex APNs device token from the OS (nil until the callback fires).
    @Published private(set) var deviceTokenHex: String?
    /// Whether the last register call reported gateway-side APNs credentials.
    @Published private(set) var gatewayAPNsConfigured: Bool?

    /// The token most recently registered, per gateway URL — avoids
    /// re-sending on every reconnect to the same gateway.
    private var registeredTokenByGateway: [String: String] = [:]

    private init() {}

    /// Ask the OS for a remote-notification device token. Safe to call
    /// repeatedly; the OS coalesces. Requires the aps-environment entitlement —
    /// without it the failure callback fires and push simply stays off.
    static func requestDeviceToken() {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Called from the app delegate's didRegisterForRemoteNotifications.
    func store(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard hex != deviceTokenHex else { return }
        deviceTokenHex = hex
        // Token changed (first launch or OS rotation) — force re-register
        // with every gateway on next sync.
        registeredTokenByGateway.removeAll()
        log.info("APNs device token acquired (\(hex.prefix(8))…)")
    }

    /// Called from the app delegate's didFailToRegister.
    func registrationFailed(_ error: Error) {
        // Expected in dev when the provisioning profile lacks the push
        // capability, and always in simulators. Push stays off; local
        // notifications continue to work.
        log.info("APNs registration unavailable: \(error.localizedDescription)")
    }

    /// Register this device with the connected gateway if we haven't yet
    /// (per gateway URL + token). Call after each successful connect.
    func syncIfNeeded(client: GatewayClient, gatewayURL: String) {
        guard let token = deviceTokenHex, !gatewayURL.isEmpty else { return }
        guard registeredTokenByGateway[gatewayURL] != token else { return }

        #if os(macOS)
        let platform = "macos"
        let deviceName = Host.current().localizedName ?? "Mac"
        #else
        let platform = "ios"
        let deviceName = UIDevice.current.name
        #endif
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        Task { @MainActor in
            do {
                let response = try await client.registerPushToken(
                    token: token,
                    platform: platform,
                    deviceName: deviceName,
                    bundleID: bundleID
                )
                registeredTokenByGateway[gatewayURL] = token
                gatewayAPNsConfigured = response.apnsConfigured
                log.info("push.register ok — gateway APNs configured: \(response.apnsConfigured)")
            } catch {
                // Older gateways don't have push.register — fine, local
                // notifications still work. Retry next reconnect.
                log.info("push.register unavailable: \(error.localizedDescription)")
            }
        }
    }
}
