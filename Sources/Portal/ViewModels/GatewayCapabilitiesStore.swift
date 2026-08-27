import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "GatewayCapabilities")

@MainActor
final class GatewayCapabilitiesStore: ObservableObject {
    @Published private(set) var capabilities: GatewayCapabilities = .conservativeDefaults
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    var hasImageInput: Bool { capabilities.hasImageInput }
    var hasACPImagePrompts: Bool { capabilities.hasACPImagePrompts }

    internal func reset(reason: String = "No harness connection") {
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

        // The negotiated capability set drives whether whole features are even
        // offered (artifact intents among them), and until now it went nowhere a
        // human could read — no view surfaces `capabilityNames`. When a feature
        // silently isn't there, this is the first thing worth checking.
        log.notice("""
        gateway capabilities resolved (\(resolved.capabilityNames.count, privacy: .public) advertised, \
        artifact actions \(resolved.supportsArtifactActions ? "supported" : "ABSENT", privacy: .public)): \
        \(resolved.capabilityNames.sorted().joined(separator: ", "), privacy: .public)
        """)

        if case .fallback(let reason) = resolved.source {
            lastRefreshError = reason
        } else {
            lastRefreshError = nil
        }
    }
}
