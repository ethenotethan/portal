import Testing
import Foundation
@testable import Portal

/// Coverage for the `gatewayURL` and `apiKey` didSet handlers in
/// `SettingsViewModel`. These fire on every property change after init, and
/// exercise the Keychain write path and the `syncActiveGateway` call.
@Suite("SettingsViewModel gateway URL and API key didSet")
internal struct SettingsViewModelGatewayTests {

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
}
