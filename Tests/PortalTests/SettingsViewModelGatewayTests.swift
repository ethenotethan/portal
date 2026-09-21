import Testing
import Foundation
@testable import Portal

/// Coverage for the `gatewayURL` and `apiKey` didSet handlers in
/// `SettingsViewModel`. These fire on every property change after init, and
/// exercise the Keychain write path and the `syncActiveGateway` call.
@Suite("SettingsViewModel gateway URL and API key didSet")
internal struct SettingsViewModelGatewayTests {

    @Test("installer handoff only prefills an empty readable harness store")
    internal func bootstrapPrefillDecisionIsFailClosed() {
        #expect(SettingsViewModel.shouldLoadBootstrap(
            hasSavedURL: false,
            hasSavedGateways: false,
            hasUnreadableStore: false,
            isUITest: false
        ))
        #expect(!SettingsViewModel.shouldLoadBootstrap(
            hasSavedURL: true,
            hasSavedGateways: false,
            hasUnreadableStore: false,
            isUITest: false
        ))
        #expect(!SettingsViewModel.shouldLoadBootstrap(
            hasSavedURL: false,
            hasSavedGateways: true,
            hasUnreadableStore: false,
            isUITest: false
        ))
        #expect(!SettingsViewModel.shouldLoadBootstrap(
            hasSavedURL: false,
            hasSavedGateways: false,
            hasUnreadableStore: true,
            isUITest: false
        ))
        #expect(!SettingsViewModel.shouldLoadBootstrap(
            hasSavedURL: false,
            hasSavedGateways: false,
            hasUnreadableStore: false,
            isUITest: true
        ))
    }

    @Test("setting gatewayURL fires the didSet handler")
    @MainActor
    internal func settingGatewayURLFiresDidSet() {
        let settings = SettingsViewModel()
        // The didSet handler checks `didCompleteInit` (true after init) and
        // calls `syncActiveGateway()` after the Keychain write. Setting the
        // URL to a different value exercises the entire didSet path.
        settings.gatewayURL = "ws://test-harness.example.com:8642/v1/ws"
        #expect(settings.gatewayURL == "ws://test-harness.example.com:8642/v1/ws")
    }

    @Test("setting apiKey fires the didSet handler")
    @MainActor
    internal func settingApiKeyFiresDidSet() {
        let settings = SettingsViewModel()
        settings.apiKey = "test-api-key-didset"
        #expect(settings.apiKey == "test-api-key-didset")
    }

    // The `gateways` account is a live account, so `saveGateways` is a no-op in
    // the test process (see KeychainStore.mayWrite); these exercise the
    // in-memory list mutation without touching the real Keychain blob.

    @Test("addGateway appends an entry that activeGateway returns")
    @MainActor
    internal func addGatewayBecomesActive() {
        let settings = SettingsViewModel()
        let before = settings.savedGateways.count
        let gateway = settings.addGateway(
            name: "Alpha", url: "ws://alpha.example.com:8642/v1/ws", apiKey: "k-alpha"
        )
        #expect(settings.savedGateways.count == before + 1)
        #expect(settings.savedGateways.contains { $0.id == gateway.id })
        // makeActive defaults true, so the new entry is the one activeGateway resolves.
        #expect(settings.activeGateway?.id == gateway.id)
        #expect(settings.isActive(gateway))
    }

    @Test("removing the active gateway falls back to another saved entry")
    @MainActor
    internal func removingActiveFallsBackToNext() {
        let settings = SettingsViewModel()
        _ = settings.addGateway(name: "First", url: "ws://first.example.com:8642/v1/ws", apiKey: "k1")
        let second = settings.addGateway(name: "Second", url: "ws://second.example.com:8642/v1/ws", apiKey: "k2")
        #expect(settings.activeGateway?.id == second.id)   // makeActive default

        settings.removeGateway(second)

        // The active entry was removed, so it falls back to a remaining one
        // rather than leaving nothing selected.
        #expect(!settings.savedGateways.contains { $0.id == second.id })
        #expect(settings.activeGateway != nil)
        #expect(settings.activeGateway?.id != second.id)
    }
}
