import Testing
@testable import Portal

@Suite("GatewayCapabilities")
struct GatewayCapabilitiesTests {
    @Test("parses direct gateway capability booleans and version")
    func parsesDirectBooleans() {
        let payload: AnyCodable = .dictionary([
            "gateway_version": .string("1.2.3"),
            "has_image_input": .bool(true),
            "has_acp_image_prompts": .bool(false),
        ])

        let capabilities = GatewayCapabilities.from(value: payload, method: "gateway.capabilities")

        #expect(capabilities.gatewayVersion == "1.2.3")
        #expect(capabilities.hasImageInput)
        #expect(!capabilities.hasACPImagePrompts)
        #expect(capabilities.source == .gateway(method: "gateway.capabilities"))
    }

    @Test("normalizes nested capability names")
    func parsesNestedCapabilityNames() {
        let payload: AnyCodable = .dictionary([
            "version": .string("2026.5"),
            "capabilities": .dictionary([
                "features": .array([
                    .string("acp.image.prompts"),
                    .string("tools"),
                ]),
                "inputs": .array([
                    .string("text"),
                    .string("image-input"),
                ]),
            ]),
        ])

        let capabilities = GatewayCapabilities.from(value: payload, method: "hermes.capabilities")

        #expect(capabilities.versionDisplay == "2026.5")
        #expect(capabilities.hasImageInput)
        #expect(capabilities.hasACPImagePrompts)
        #expect(capabilities.capabilityNames.contains("acp.image.prompts"))
    }

    @Test("scalar version responses preserve their reporting source")
    internal func parsesScalarVersions() {
        let gateway = GatewayCapabilities.from(
            value: .string("1.2.3"),
            method: "gateway.version"
        )
        let agent = GatewayCapabilities.from(
            value: .int(42),
            method: "hermes.version"
        )

        #expect(gateway.gatewayVersion == "1.2.3")
        #expect(gateway.agentVersion == nil)
        #expect(gateway.source == .gateway(method: "gateway.version"))
        #expect(agent.gatewayVersion == nil)
        #expect(agent.agentVersion == "42")
        #expect(agent.source == .gateway(method: "hermes.version"))
    }

    @Test("a nil reported result stays distinct from a transport fallback")
    internal func nilResultUsesGatewaySource() {
        let capabilities = GatewayCapabilities.from(
            result: nil,
            method: "gateway.capabilities"
        )

        #expect(capabilities.gatewayVersion == nil)
        #expect(capabilities.agentVersion == nil)
        #expect(capabilities.capabilityNames.isEmpty)
        #expect(!capabilities.hasImageInput)
        #expect(!capabilities.hasACPImagePrompts)
        #expect(capabilities.source == .gateway(method: "gateway.capabilities"))
        #expect(capabilities.statusDisplay == "Detected")
    }

    @Test("fallback is conservative for image features")
    func fallbackIsConservative() {
        let capabilities = GatewayCapabilities.fallback(reason: "unsupported")

        #expect(!capabilities.hasImageInput)
        #expect(!capabilities.hasACPImagePrompts)
        #expect(capabilities.versionDisplay == "Unknown")
        #expect(capabilities.statusDisplay == "Not reported")
    }
}
