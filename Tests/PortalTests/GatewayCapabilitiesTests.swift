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

    @Test("action-log support recognizes both advertised wire spellings")
    internal func actionLogCapabilityVariants() {
        for name in ["artifact.action.log", "artifact_action_log"] {
            let capabilities = GatewayCapabilities(
                gatewayVersion: nil, agentVersion: nil,
                capabilityNames: [name],
                hasImageInput: false, hasACPImagePrompts: false,
                source: .gateway(method: "gateway.capabilities")
            )
            #expect(capabilities.supportsActionLog, "\(name) should enable the action ledger")
        }

        let invokeOnly = GatewayCapabilities(
            gatewayVersion: nil, agentVersion: nil,
            capabilityNames: ["artifact.action.invoke"],
            hasImageInput: false, hasACPImagePrompts: false,
            source: .gateway(method: "gateway.capabilities")
        )
        #expect(!invokeOnly.supportsActionLog)
    }

    @Test("the diagnostic summary names the count, the intent verdict, and the set")
    internal func diagnosticSummaryReportsTheNegotiatedSet() {
        let supported = GatewayCapabilities(
            gatewayVersion: "1.2.3", agentVersion: nil,
            capabilityNames: ["artifact.action.invoke", "learning.courses"],
            hasImageInput: false, hasACPImagePrompts: false,
            source: .gateway(method: "gateway.capabilities")
        )
        // Sorted, so two gateways advertising the same set produce the same
        // line — a Set's iteration order would make these undiffable.
        #expect(supported.diagnosticSummary
                == "2 advertised, artifact actions supported: artifact.action.invoke, learning.courses")

        // The case that matters when intents are silently missing: the verdict
        // has to be loud, and an empty set must not render as a bare colon.
        let absent = GatewayCapabilities.fallback(reason: "no connection")
        #expect(absent.diagnosticSummary == "0 advertised, artifact actions ABSENT: none listed")
    }

    @Test("fallback is conservative for image features")
    func fallbackIsConservative() {
        let capabilities = GatewayCapabilities.fallback(reason: "unsupported")

        #expect(!capabilities.hasImageInput)
        #expect(!capabilities.hasACPImagePrompts)
        #expect(capabilities.versionDisplay == "Unknown")
        #expect(capabilities.statusDisplay == "Not reported")
    }

    @MainActor
    @Test("capability store reset returns to a conservative disconnected state")
    internal func storeResetIsConservative() {
        let store = GatewayCapabilitiesStore()

        #expect(!store.isRefreshing)
        #expect(store.lastRefreshError == nil)

        store.reset(reason: "Gateway disconnected")

        #expect(store.capabilities.source == .fallback(reason: "Gateway disconnected"))
        #expect(!store.hasImageInput)
        #expect(!store.hasACPImagePrompts)
        #expect(store.lastRefreshError == nil)
        #expect(!store.isRefreshing)
    }
}
