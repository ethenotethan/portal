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
            if didCompleteInit {
                KeychainStore.shared.saveGatewayURL(gatewayURL)
                syncActiveGateway()
            }
        }
    }
    @Published var apiKey: String {
        didSet {
            if didCompleteInit {
                KeychainStore.shared.saveAPIKey(apiKey)
                syncActiveGateway()
            }
        }
    }
    @Published var isConfigured: Bool = false

    /// Saved gateways the user can switch between. The active one's
    /// `url`/`apiKey` are mirrored into `gatewayURL`/`apiKey` above so the
    /// existing connect path keeps working. Persisted to the Keychain.
    @Published private(set) var savedGateways: [SavedGateway] = []

    /// ID of the currently-active saved gateway (persisted in UserDefaults).
    @Published private(set) var activeGatewayID: UUID? {
        didSet {
            if didCompleteInit {
                UserDefaults.standard.set(activeGatewayID?.uuidString, forKey: Self.activeGatewayIDKey)
            }
        }
    }
    private static let activeGatewayIDKey = "hermes.activeGatewayID"
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

    // MARK: - Centaur Backends

    /// Centaur entries in the unified backend list. Centaur backends are
    /// per-session targets (chosen at session create), never the app-level
    /// active gateway — the ambient services (session list, wiki, skills,
    /// cron) always ride the active Hermes entry.
    var centaurBackends: [SavedGateway] {
        savedGateways.filter { $0.kind == .centaur }
    }

    var hermesBackends: [SavedGateway] {
        savedGateways.filter { $0.kind == .hermes }
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
        self.isConfigured = onboarded || (isUITest && !(uiTestGatewayURL?.isEmpty ?? true))

        // Load saved gateways. Migrate the existing single gateway into the
        // list on first launch so users who already configured a gateway keep
        // it as a switchable entry.
        var loadedGateways = KeychainStore.shared.loadGateways()
        let restoredActiveID = UserDefaults.standard.string(forKey: Self.activeGatewayIDKey)
            .flatMap(UUID.init(uuidString:))
        if loadedGateways.isEmpty, onboarded || !self.apiKey.isEmpty {
            let migrated = SavedGateway(
                name: URL(string: resolvedGatewayURL)?.host ?? "Gateway",
                url: resolvedGatewayURL,
                apiKey: self.apiKey
            )
            loadedGateways = [migrated]
            self.savedGateways = loadedGateways
            self.activeGatewayID = migrated.id
            KeychainStore.shared.saveGateways(loadedGateways)
            UserDefaults.standard.set(migrated.id.uuidString, forKey: Self.activeGatewayIDKey)
        } else {
            self.savedGateways = loadedGateways
            // Resolve the active entry: prefer the persisted ID, else the entry
            // whose URL matches the active gateway URL.
            self.activeGatewayID = restoredActiveID.flatMap { id in
                loadedGateways.first { $0.id == id }?.id
            } ?? loadedGateways.first { $0.url == resolvedGatewayURL }?.id
        }

        didCompleteInit = true

        if isUITest {
            log.info("UITest settings gatewayURL=\(self.gatewayURL) apiKeySet=\(!self.apiKey.isEmpty)")
        }
    }

    // MARK: - Multi-Gateway Management

    /// Whether the given gateway is the currently-active one.
    func isActive(_ gateway: SavedGateway) -> Bool {
        gateway.id == activeGatewayID
    }

    /// Switch the active gateway. Writes the chosen gateway's URL/API key into
    /// the active settings (which triggers the existing reconnect path observed
    /// in ContentView) and clears the in-memory CF Access cookie so a CF-gated
    /// gateway re-auths. No-op if already active.
    func selectGateway(_ gateway: SavedGateway) {
        guard gateway.id != activeGatewayID else { return }
        guard savedGateways.contains(where: { $0.id == gateway.id }) else { return }
        // Centaur backends are session-create targets, not the app gateway:
        // activating one would tear down the WebSocket that powers the
        // session list, wiki, skills, and cron with nothing to replace it.
        guard gateway.kind == .hermes else { return }

        activeGatewayID = gateway.id
        // The CF cookie is host-specific; drop it so the new host re-auths.
        cfAuthCookie = nil
        cfAuthEmail = nil
        // Setting these mirrors into the Keychain via didSet and triggers the
        // reconnect observers. Set apiKey first so the URL change (which the
        // connect path keys on) sees the new key already in place.
        apiKey = gateway.apiKey
        gatewayURL = gateway.url
    }

    /// Add a new saved gateway. Returns the created entry.
    @discardableResult
    func addGateway(name: String, url: String, apiKey: String, kind: BackendKind = .hermes, makeActive: Bool = true) -> SavedGateway {
        let gateway = SavedGateway(name: name, url: url, apiKey: apiKey, kind: kind)
        savedGateways.append(gateway)
        persistGateways()
        if makeActive && kind == .hermes { selectGateway(gateway) }
        return gateway
    }

    /// Update an existing saved gateway's fields. If it is the active gateway,
    /// the live connection settings are updated too.
    func updateGateway(_ gateway: SavedGateway) {
        guard let index = savedGateways.firstIndex(where: { $0.id == gateway.id }) else { return }
        savedGateways[index] = gateway
        persistGateways()
        if gateway.id == activeGatewayID {
            if apiKey != gateway.apiKey { apiKey = gateway.apiKey }
            if gatewayURL != gateway.url { gatewayURL = gateway.url }
        }
    }

    /// Remove a saved gateway. If it was active, falls back to the first
    /// remaining gateway (if any).
    func removeGateway(_ gateway: SavedGateway) {
        savedGateways.removeAll { $0.id == gateway.id }
        persistGateways()
        if gateway.id == activeGatewayID {
            if let next = savedGateways.first(where: { $0.kind == .hermes }) {
                activeGatewayID = nil  // force selectGateway to run
                selectGateway(next)
            } else {
                activeGatewayID = nil
            }
        }
    }

    /// Keep the active saved-gateway entry in sync when the user edits the live
    /// URL/API key fields directly (e.g. in Settings or Onboarding).
    private func syncActiveGateway() {
        guard let id = activeGatewayID,
              let index = savedGateways.firstIndex(where: { $0.id == id }) else {
            // No active entry yet (fresh onboarding) — create one once a URL
            // and key exist so the picker has something to show.
            if !gatewayURL.isEmpty, savedGateways.isEmpty {
                let gateway = SavedGateway(
                    name: URL(string: gatewayURL)?.host ?? "Gateway",
                    url: gatewayURL,
                    apiKey: apiKey
                )
                savedGateways = [gateway]
                activeGatewayID = gateway.id
                persistGateways()
            }
            return
        }
        var updated = savedGateways[index]
        guard updated.url != gatewayURL || updated.apiKey != apiKey else { return }
        updated.url = gatewayURL
        updated.apiKey = apiKey
        savedGateways[index] = updated
        persistGateways()
    }

    private func persistGateways() {
        KeychainStore.shared.saveGateways(savedGateways)
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
