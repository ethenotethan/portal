import Foundation
import Combine

/// Manages connection settings: gateway URL, API key, and CF Access service token.
final class SettingsViewModel: ObservableObject {
    @Published var gatewayURL: String {
        didSet { KeychainStore.shared.saveGatewayURL(gatewayURL) }
    }
    @Published var apiKey: String {
        didSet { KeychainStore.shared.saveAPIKey(apiKey) }
    }
    @Published var cfAccessClientId: String {
        didSet { KeychainStore.shared.saveCFAccessClientId(cfAccessClientId) }
    }
    @Published var cfAccessClientSecret: String {
        didSet { KeychainStore.shared.saveCFAccessClientSecret(cfAccessClientSecret) }
    }
    @Published var isConfigured: Bool = false

    init() {
        self.gatewayURL = KeychainStore.shared.loadGatewayURL() ?? Constants.defaultGatewayURL
        self.apiKey = KeychainStore.shared.loadAPIKey() ?? ""
        self.cfAccessClientId = KeychainStore.shared.loadCFAccessClientId() ?? ""
        self.cfAccessClientSecret = KeychainStore.shared.loadCFAccessClientSecret() ?? ""
        self.isConfigured = !gatewayURL.isEmpty
    }

    /// Validate and update the configured state.
    func validate() {
        isConfigured = !gatewayURL.isEmpty
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
            // Strip trailing slash
            urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            urlString += "/v1/ws"
        }

        return URL(string: urlString)
    }

    /// Build a GatewayClient from current settings.
    @MainActor
    func makeGatewayClient() -> GatewayClient? {
        guard let wsURL = buildWebSocketURL() else { return nil }
        return GatewayClient(
            gatewayURL: wsURL,
            apiKey: apiKey,
            cfAccessClientId: cfAccessClientId,
            cfAccessClientSecret: cfAccessClientSecret
        )
    }
}
