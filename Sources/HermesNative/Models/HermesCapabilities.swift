import Foundation

/// Normalized capability data reported by the Hermes gateway.
struct HermesCapabilities: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case gateway(method: String)
        case fallback(reason: String)

        var label: String {
            switch self {
            case .gateway(let method): method
            case .fallback: "conservative defaults"
            }
        }
    }

    var gatewayVersion: String?
    var hermesVersion: String?
    var capabilityNames: Set<String>
    var hasImageInput: Bool
    var hasACPImagePrompts: Bool
    var source: Source

    var versionDisplay: String {
        gatewayVersion ?? hermesVersion ?? "Unknown"
    }

    var statusDisplay: String {
        switch source {
        case .gateway:
            return "Detected"
        case .fallback:
            return "Not reported"
        }
    }

    var supportsImagePrompts: Bool {
        hasImageInput || hasACPImagePrompts
    }

    static let conservativeDefaults = HermesCapabilities(
        gatewayVersion: nil,
        hermesVersion: nil,
        capabilityNames: [],
        hasImageInput: false,
        hasACPImagePrompts: false,
        source: .fallback(reason: "Gateway did not report capabilities")
    )

    static func fallback(reason: String) -> HermesCapabilities {
        var capabilities = conservativeDefaults
        capabilities.source = .fallback(reason: reason)
        return capabilities
    }

    static func from(result: AnyCodable?, method: String) -> HermesCapabilities {
        guard let result else {
            var capabilities = conservativeDefaults
            capabilities.source = .gateway(method: method)
            return capabilities
        }
        return from(value: result, method: method)
    }

    static func from(value: AnyCodable, method: String) -> HermesCapabilities {
        if value.dictionaryValue == nil,
           let version = value.stringValue ?? value.intValue.map({ String($0) }) ?? value.doubleValue.map({ String($0) }) {
            return HermesCapabilities(
                gatewayVersion: method.contains("gateway") ? version : nil,
                hermesVersion: method.contains("hermes") ? version : nil,
                capabilityNames: [],
                hasImageInput: false,
                hasACPImagePrompts: false,
                source: .gateway(method: method)
            )
        }

        let root = value.dictionaryValue ?? [:]
        let nested = firstDictionary(in: root, keys: ["capabilities", "features", "data", "result", "gateway", "hermes"])
        let capabilityContainer = nested ?? root

        let names = normalizedCapabilityNames(from: value)
            .union(normalizedCapabilityNames(from: .dictionary(capabilityContainer)))

        let gatewayVersion = firstString(in: root, keys: [
            "gateway_version", "gatewayVersion", "version", "server_version", "serverVersion"
        ]) ?? firstString(in: capabilityContainer, keys: [
            "gateway_version", "gatewayVersion", "version", "server_version", "serverVersion"
        ])

        let hermesVersion = firstString(in: root, keys: [
            "hermes_version", "hermesVersion", "agent_version", "agentVersion", "version"
        ]) ?? firstString(in: capabilityContainer, keys: [
            "hermes_version", "hermesVersion", "agent_version", "agentVersion", "version"
        ])

        return HermesCapabilities(
            gatewayVersion: gatewayVersion,
            hermesVersion: hermesVersion,
            capabilityNames: names,
            hasImageInput: boolCapability(
                names: names,
                root: root,
                container: capabilityContainer,
                boolKeys: ["has_image_input", "hasImageInput", "image_input", "imageInput", "vision", "supports_images", "supportsImages"],
                nameFragments: ["image.input", "image_input", "image-input", "vision", "multimodal", "images"]
            ),
            hasACPImagePrompts: boolCapability(
                names: names,
                root: root,
                container: capabilityContainer,
                boolKeys: ["has_acp_image_prompts", "hasACPImagePrompts", "acp_image_prompts", "acpImagePrompts", "image_prompts", "imagePrompts"],
                nameFragments: ["acp.image", "acp_image", "acp-image", "image.prompt", "image_prompt", "image-prompt"]
            ),
            source: .gateway(method: method)
        )
    }

    private static func boolCapability(
        names: Set<String>,
        root: [String: AnyCodable],
        container: [String: AnyCodable],
        boolKeys: [String],
        nameFragments: [String]
    ) -> Bool {
        for key in boolKeys {
            if root[key]?.boolValue == true || container[key]?.boolValue == true {
                return true
            }
            if root[key]?.stringValue.map(normalizedTruth) == true || container[key]?.stringValue.map(normalizedTruth) == true {
                return true
            }
        }

        return names.contains { name in
            nameFragments.contains { fragment in name.contains(fragment) }
        }
    }

    private static func normalizedTruth(_ value: String) -> Bool {
        ["true", "yes", "1", "supported", "enabled"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func firstString(in dictionary: [String: AnyCodable], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key]?.stringValue, !value.isEmpty {
                return value
            }
            if let intValue = dictionary[key]?.intValue {
                return String(intValue)
            }
            if let doubleValue = dictionary[key]?.doubleValue {
                return String(doubleValue)
            }
        }
        return nil
    }

    private static func firstDictionary(in dictionary: [String: AnyCodable], keys: [String]) -> [String: AnyCodable]? {
        for key in keys {
            if let nested = dictionary[key]?.dictionaryValue {
                return nested
            }
        }
        return nil
    }

    private static func normalizedCapabilityNames(from value: AnyCodable) -> Set<String> {
        var names = Set<String>()
        collectCapabilityNames(from: value, into: &names)
        return names
    }

    private static func collectCapabilityNames(from value: AnyCodable, into names: inout Set<String>) {
        switch value {
        case .string(let string):
            let normalized = normalizeName(string)
            if !normalized.isEmpty { names.insert(normalized) }
        case .array(let array):
            array.forEach { collectCapabilityNames(from: $0, into: &names) }
        case .dictionary(let dictionary):
            for (key, value) in dictionary {
                if value.boolValue == true {
                    let normalized = normalizeName(key)
                    if !normalized.isEmpty { names.insert(normalized) }
                }

                if ["capabilities", "features", "supported", "supports", "modalities", "inputs"].contains(normalizeName(key)) {
                    collectCapabilityNames(from: value, into: &names)
                } else if value.dictionaryValue != nil || value.arrayValue != nil {
                    collectCapabilityNames(from: value, into: &names)
                }
            }
        case .int, .double, .bool, .null:
            break
        }
    }

    private static func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}
