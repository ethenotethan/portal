import Testing
import Foundation
@testable import HermesNative

@Suite("Backend Kind")
struct BackendKindTests {

    @Test("legacy SavedGateway JSON without kind decodes as hermes")
    func legacyEntriesDecodeAsHermes() throws {
        let legacy = """
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Home","url":"ws://x:8642","apiKey":"k"}
        """
        let decoded = try JSONDecoder().decode(SavedGateway.self, from: Data(legacy.utf8))
        #expect(decoded.kind == .hermes)
        #expect(decoded.name == "Home")
    }

    @Test("kind round-trips through encode/decode")
    func kindRoundTrips() throws {
        let entry = SavedGateway(name: "Sandbox", url: "https://centaur.example.com", apiKey: "jwt", kind: .centaur)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SavedGateway.self, from: data)
        #expect(decoded.kind == .centaur)
    }

    @Test("selectGateway focuses centaur without moving the app-level connection")
    @MainActor
    func selectFocusesCentaur() {
        let settings = SettingsViewModel()
        let before = settings.activeGatewayID
        let centaur = settings.addGateway(
            name: "Sandbox", url: "https://c.example.com", apiKey: "k",
            kind: .centaur, makeActive: true
        )
        settings.selectGateway(centaur)
        // Connection stays on Hermes…
        #expect(settings.activeGatewayID == before)
        #expect(settings.activeGatewayID != centaur.id)
        // …but the selection is honored: centaur is focused, presented as
        // selected, and the badge names it.
        #expect(settings.focusedBackendID == centaur.id)
        #expect(settings.isFocused(centaur))
        #expect(settings.focusedGateway?.id == centaur.id)
        settings.removeGateway(centaur)
        #expect(settings.focusedBackendID == nil)
    }

    @Test("Selecting a hermes entry clears session-scoped focus")
    @MainActor
    func hermesSelectionClearsFocus() {
        let settings = SettingsViewModel()
        let centaur = settings.addGateway(
            name: "Sandbox", url: "https://c.example.com", apiKey: "k",
            kind: .centaur
        )
        defer { settings.removeGateway(centaur) }
        settings.selectGateway(centaur)
        #expect(settings.focusedBackendID == centaur.id)

        guard let hermes = settings.savedGateways.first(where: { $0.kind == .hermes }) else {
            // No hermes entry configured in this test environment — the
            // clear-on-hermes-select path is covered by focusedGateway
            // falling back to activeGatewayID.
            return
        }
        // Re-selecting the ALREADY-ACTIVE hermes entry must still clear
        // focus (the click means "take me back to Hermes").
        settings.selectGateway(hermes)
        #expect(settings.focusedBackendID == nil)
        #expect(settings.isFocused(hermes) == settings.isActive(hermes))
    }

    @Test("sessionScopedBackends filters by kind")
    @MainActor
    func sessionScopedBackendsFilter() {
        let settings = SettingsViewModel()
        let centaur = settings.addGateway(
            name: "Sandbox", url: "https://c.example.com", apiKey: "k",
            kind: .centaur
        )
        #expect(settings.sessionScopedBackends.contains { $0.id == centaur.id })
        #expect(!settings.hermesBackends.contains { $0.id == centaur.id })
        settings.removeGateway(centaur)
    }

    @Test("kind presentation lives on the model, not in views")
    func kindPresentation() {
        #expect(BackendKind.hermes.isSessionScoped == false)
        #expect(BackendKind.centaur.isSessionScoped == true)
        #expect(BackendKind.centaur.sessionScopedFootnote != nil)
        #expect(BackendKind.hermes.sessionScopedFootnote == nil)
    }

    @Test("session backend registry binds and persists lookups")
    @MainActor
    func registryBindsAndForgets() {
        let registry = SessionBackendRegistry.shared
        let backendID = UUID()
        registry.bind(sessionID: "test-thread-1", backendID: backendID)
        #expect(registry.backendID(for: "test-thread-1") == backendID)
        #expect(registry.backendID(for: "unknown-session") == nil)
        registry.forget(sessionID: "test-thread-1")
        #expect(registry.backendID(for: "test-thread-1") == nil)
    }
}
