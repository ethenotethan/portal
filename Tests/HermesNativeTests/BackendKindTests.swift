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

    @Test("selectGateway refuses centaur entries as the app-level gateway")
    @MainActor
    func selectRefusesCentaur() {
        let settings = SettingsViewModel()
        let before = settings.activeGatewayID
        let centaur = settings.addGateway(
            name: "Sandbox", url: "https://c.example.com", apiKey: "k",
            kind: .centaur, makeActive: true
        )
        // makeActive is ignored for centaur; explicit select is refused too.
        settings.selectGateway(centaur)
        #expect(settings.activeGatewayID == before)
        #expect(settings.activeGatewayID != centaur.id)
        settings.removeGateway(centaur)
    }

    @Test("centaurBackends filters by kind")
    @MainActor
    func centaurBackendsFilter() {
        let settings = SettingsViewModel()
        let centaur = settings.addGateway(
            name: "Sandbox", url: "https://c.example.com", apiKey: "k",
            kind: .centaur
        )
        #expect(settings.centaurBackends.contains { $0.id == centaur.id })
        #expect(!settings.hermesBackends.contains { $0.id == centaur.id })
        settings.removeGateway(centaur)
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
