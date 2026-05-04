import Foundation

@MainActor
final class HermesCapabilitiesStore: ObservableObject {
    @Published private(set) var capabilities: HermesCapabilities = .conservativeDefaults
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    var hasImageInput: Bool { capabilities.hasImageInput }
    var hasACPImagePrompts: Bool { capabilities.hasACPImagePrompts }

    func reset(reason: String = "No gateway connection") {
        capabilities = .fallback(reason: reason)
        lastRefreshError = nil
        isRefreshing = false
    }

    func refresh(using client: GatewayClient) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let resolved = await client.capabilities()
        capabilities = resolved

        if case .fallback(let reason) = resolved.source {
            lastRefreshError = reason
        } else {
            lastRefreshError = nil
        }
    }
}
