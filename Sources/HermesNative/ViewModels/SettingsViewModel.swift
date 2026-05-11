import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SettingsViewModel")

/// Manages connection settings: gateway URL, API key, and CF Access auth state.
@MainActor
final class SettingsViewModel: ObservableObject {
    static let responseCompleteNotificationsKey = "hermes.responseCompleteNotificationsEnabled"

    @Published var gatewayURL: String {
        didSet {
            if didCompleteInit { KeychainStore.shared.saveGatewayURL(gatewayURL) }
        }
    }
    @Published var apiKey: String {
        didSet {
            if didCompleteInit { KeychainStore.shared.saveAPIKey(apiKey) }
        }
    }
    @Published var isConfigured: Bool = false
    @Published var responseCompleteNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(responseCompleteNotificationsEnabled, forKey: Self.responseCompleteNotificationsKey)
        }
    }

    private static let onboardingCompleteKey = "hermes.onboardingComplete"
    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey)
    }
    private var didCompleteInit = false

    /// Whether the gateway domain likely requires CF Access auth.
    var needsCFAuth: Bool {
        guard let host = buildWebSocketURL()?.host else { return false }
        // Local addresses don't need CF Access
        return !host.hasPrefix("127.0.0.1") &&
               !host.hasPrefix("localhost") &&
               !host.hasPrefix("192.168.") &&
               !host.hasPrefix("10.")
    }

    /// The captured CF_Authorization cookie (not persisted — re-auth on app launch).
    @Published var cfAuthCookie: HTTPCookie?

    /// Email extracted from CF Access JWT (for display purposes).
    @Published var cfAuthEmail: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        let isUITest = args.contains("--uitest")
        let uiTestGatewayURL = isUITest ? env["HERMES_NATIVE_GATEWAY_URL"] : nil
        let uiTestAPIKey = isUITest ? (env["HERMES_NATIVE_API_KEY"] ?? env["API_SERVER_KEY"]) : nil

        let savedURL = KeychainStore.shared.loadGatewayURL()
        let resolvedGatewayURL = uiTestGatewayURL ?? savedURL ?? Constants.defaultGatewayURL
        self.gatewayURL = resolvedGatewayURL
        self.apiKey = uiTestAPIKey ?? KeychainStore.shared.loadAPIKey() ?? ""
        self.responseCompleteNotificationsEnabled = UserDefaults.standard.object(forKey: Self.responseCompleteNotificationsKey) as? Bool ?? true

        let onboarded = UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey)
            || (savedURL != nil && savedURL != Constants.defaultGatewayURL)
        self.isConfigured = onboarded || (isUITest && uiTestGatewayURL != nil)
        didCompleteInit = true

        if isUITest {
            log.info("UITest settings gatewayURL=\(self.gatewayURL) apiKeySet=\(!self.apiKey.isEmpty)")
        }
    }

    /// Validate and update the configured state.
    func validate() {
        guard !gatewayURL.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        isConfigured = true
    }

    /// Build the WebSocket URL from the configured gateway URL.
    func buildWebSocketURL() -> URL? {
        var urlString = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the user entered an HTTP(S) URL, convert to WS(S)
        if urlString.hasPrefix("https://") {
            urlString = "wss://" + urlString.dropFirst("https://".count)
        } else if urlString.hasPrefix("http://") {
            urlString = "ws://" + urlString.dropFirst("http://".count)
        }

        // Append /v1/ws path if not already present
        if !urlString.hasSuffix("/v1/ws") && !urlString.hasSuffix("/api/ws") {
            urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            urlString += "/v1/ws"
        }

        return URL(string: urlString)
    }

    /// Build a GatewayClient from current settings.
    func makeGatewayClient() -> GatewayClient? {
        guard let wsURL = buildWebSocketURL() else { return nil }
        let client = GatewayClient(gatewayURL: wsURL, apiKey: apiKey)
        client.cfAuthCookie = cfAuthCookie
        return client
    }

    /// Extract email from CF_Authorization JWT payload (for display).
    func parseCFAuthEmail(from cookie: HTTPCookie) {
        // JWT format: header.payload.signature
        let parts = cookie.value.split(separator: ".")
        guard parts.count == 3 else { return }
        // Decode payload (base64url)
        let payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = payload.padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else { return }
        self.cfAuthEmail = email
    }
}
