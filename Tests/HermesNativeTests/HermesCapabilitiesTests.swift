import Testing
@testable import HermesNative

@Suite("HermesCapabilities")
struct HermesCapabilitiesTests {
    @Test("parses direct gateway capability booleans and version")
    func parsesDirectBooleans() {
        let payload: AnyCodable = .dictionary([
            "gateway_version": .string("1.2.3"),
            "has_image_input": .bool(true),
            "has_acp_image_prompts": .bool(false),
        ])

        let capabilities = HermesCapabilities.from(value: payload, method: "gateway.capabilities")

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

        let capabilities = HermesCapabilities.from(value: payload, method: "hermes.capabilities")

        #expect(capabilities.versionDisplay == "2026.5")
        #expect(capabilities.hasImageInput)
        #expect(capabilities.hasACPImagePrompts)
        #expect(capabilities.capabilityNames.contains("acp.image.prompts"))
    }

    @Test("fallback is conservative for image features")
    func fallbackIsConservative() {
        let capabilities = HermesCapabilities.fallback(reason: "unsupported")

        #expect(!capabilities.hasImageInput)
        #expect(!capabilities.hasACPImagePrompts)
        #expect(capabilities.versionDisplay == "Unknown")
        #expect(capabilities.statusDisplay == "Not reported")
    }
}
