import Testing
import Foundation
@testable import Portal

@Suite("Gateway persona")
internal struct GatewayPersonaTests {

    // MARK: - Gateway → Persona derivation

    @Test("a gateway's name is the persona name")
    internal func gatewayNameIsPersonaName() {
        let gateway = SavedGateway(name: "Hank, Bob", url: "wss://x", apiKey: "k")
        let persona = PersonaManager.persona(for: gateway)
        #expect(persona.name == "Hank, Bob")
    }

    @Test("the persona id is the gateway id, so the identicon seed is stable")
    internal func personaSeededFromGatewayID() {
        let id = UUID()
        let gateway = SavedGateway(id: id, name: "Cosmos", url: "wss://x", apiKey: "k")
        let persona = PersonaManager.persona(for: gateway)
        #expect(persona.id == id.uuidString)
    }

    @Test("a gateway persona is not built-in, so it renders an identicon")
    internal func gatewayPersonaUsesIdenticon() {
        let gateway = SavedGateway(name: "Cosmos", url: "wss://x", apiKey: "k")
        let persona = PersonaManager.persona(for: gateway)
        #expect(persona.isBuiltIn == false)
        // No uploaded image → falls back to the generated identicon.
        #expect(persona.hasCustomImage == false)
    }

    @Test("an uploaded avatar path flows onto the persona")
    internal func uploadedAvatarPathPropagates() {
        var gateway = SavedGateway(name: "Cosmos", url: "wss://x", apiKey: "k")
        gateway.avatarImagePath = "/tmp/does-not-exist.png"
        let persona = PersonaManager.persona(for: gateway)
        #expect(persona.imagePath == "/tmp/does-not-exist.png")
        // Missing file → hasCustomImage is false, so it still falls back cleanly.
        #expect(persona.hasCustomImage == false)
    }

    @Test("an empty gateway name falls back to the host as the persona name")
    internal func emptyNameFallsBackToHost() {
        let gateway = SavedGateway(name: "  ", url: "wss://gateway.example.com:8080", apiKey: "k")
        let persona = PersonaManager.persona(for: gateway)
        #expect(persona.name == "gateway.example.com")
    }

    // MARK: - Chrome persona precedence (gateway always wins)

    @Test("an adopted gateway persona beats the Centaur harness identity")
    @MainActor
    internal func gatewayPersonaBeatsHarness() {
        let manager = PersonaManager()
        let gateway = SavedGateway(name: "Cosmos", url: "wss://x", apiKey: "k")
        manager.adoptGatewayPersona(gateway)
        // Even on a Centaur (harness-fixed) backend, the gateway persona wins.
        let shown = manager.chromePersona(harness: .centaurPersona)
        #expect(shown.name == "Cosmos")
        #expect(shown.id == gateway.id.uuidString)
    }

    @Test("with no gateway persona adopted, the harness identity is the fallback")
    @MainActor
    internal func harnessFallbackWhenNoGatewayPersona() {
        let manager = PersonaManager()  // activePersona == .defaultPersona (built-in)
        let shown = manager.chromePersona(harness: .centaurPersona)
        #expect(shown == .centaurPersona)
    }

    @Test("with no harness and no adoption, the default persona shows")
    @MainActor
    internal func defaultWhenNoHarnessNoAdoption() {
        let manager = PersonaManager()
        let shown = manager.chromePersona(harness: nil)
        #expect(shown == .defaultPersona)
    }

    // MARK: - SavedGateway backward-compatible decoding

    @Test("a gateway JSON without avatarImagePath decodes with a nil avatar")
    internal func decodesLegacyGatewayWithoutAvatar() throws {
        let jsonString = """
        {"id":"\(UUID().uuidString)","name":"Old","url":"wss://x","apiKey":"k","kind":"hermes"}
        """
        let json = Data(jsonString.utf8)
        let gateway = try JSONDecoder().decode(SavedGateway.self, from: json)
        #expect(gateway.avatarImagePath == nil)
        #expect(gateway.name == "Old")
    }

    @Test("a gateway round-trips its avatar path through Codable")
    internal func avatarPathRoundTrips() throws {
        var gateway = SavedGateway(name: "Cosmos", url: "wss://x", apiKey: "k")
        gateway.avatarImagePath = "/tmp/persona-abc.png"
        let data = try JSONEncoder().encode(gateway)
        let decoded = try JSONDecoder().decode(SavedGateway.self, from: data)
        #expect(decoded.avatarImagePath == "/tmp/persona-abc.png")
        #expect(decoded == gateway)
    }
}

@Suite("Identicon")
internal struct IdenticonTests {

    @Test("the same seed always produces the same hash (stable across launches)")
    internal func stableHashIsDeterministic() {
        let a = Identicon.stableHash("gateway-abc")
        let b = Identicon.stableHash("gateway-abc")
        #expect(a == b)
    }

    @Test("different seeds produce different hashes")
    internal func differentSeedsDiffer() {
        #expect(Identicon.stableHash("alpha") != Identicon.stableHash("beta"))
    }

    @Test("the identicon grid is 5×5 and mirrored across the vertical axis")
    internal func gridIsSymmetric() {
        let grid = Identicon.grid(for: "some-gateway-id")
        #expect(grid.count == 5)
        for row in grid {
            #expect(row.count == 5)
            // Column j mirrors column (4 - j).
            #expect(row[0] == row[4])
            #expect(row[1] == row[3])
        }
    }

    @Test("the same seed yields an identical grid every time")
    internal func gridIsDeterministic() {
        #expect(Identicon.grid(for: "x") == Identicon.grid(for: "x"))
    }

    @Test("the hue is within the unit interval")
    internal func hueInRange() {
        let hue = Identicon.hue(for: "anything")
        #expect(hue >= 0.0)
        #expect(hue < 1.0)
    }
}
