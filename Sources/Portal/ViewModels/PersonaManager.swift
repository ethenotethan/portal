import SwiftUI
import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "PersonaManager")

/// Manages persona identity: auto-derives from the gateway's PERSONA.md + config.
@MainActor
final class PersonaManager: ObservableObject {
    @Published var activePersona: Persona = .defaultPersona

    init() {}

    /// Adopt the persona for a saved gateway. The gateway's **name is the
    /// persona name** ("Hank, Bob" → a persona called "Hank, Bob"), its `id`
    /// seeds the identicon so every gateway gets a distinct default face, and an
    /// uploaded `avatarImagePath` becomes the persona picture. This gateway
    /// persona always wins over the built-in Portal/Centaur glyph — clicking
    /// into a gateway addresses that persona.
    ///
    /// `isBuiltIn: false` marks it as identicon-eligible (see `Persona.avatar`).
    internal func adoptGatewayPersona(_ gateway: SavedGateway) {
        activePersona = Self.persona(for: gateway)
    }

    /// The identity chat chrome should present, given the current backend's
    /// optional harness-fixed persona (`BackendCapabilities.harnessPersona`).
    ///
    /// A gateway persona — one adopted via `adoptGatewayPersona`, marked
    /// `isBuiltIn == false` — **always wins**: clicking into a gateway addresses
    /// that gateway's persona by name, even over a built-in harness identity
    /// like Centaur. The harness persona is used only as a fallback while no
    /// gateway persona has been adopted yet (e.g. the launch default).
    internal func chromePersona(harness: Persona?) -> Persona {
        if !activePersona.isBuiltIn { return activePersona }
        return harness ?? activePersona
    }

    /// Build (without adopting) the persona a saved gateway represents. Pure so
    /// it's testable and reusable by menu-bar / header previews — `nonisolated`
    /// because it touches no actor state.
    nonisolated internal static func persona(for gateway: SavedGateway) -> Persona {
        Persona(
            id: gateway.id.uuidString,
            name: gateway.displayName,
            tagline: gateway.kind.displayName,
            symbolName: gateway.kind.iconName,
            accentColorHex: "#5856D6",
            imagePath: gateway.avatarImagePath,
            systemPromptSuffix: nil,
            isBuiltIn: false,
            isAgentDefault: false
        )
    }

    /// Derive the persona from the connected Hermes Agent config.
    func syncFromGateway(_ client: GatewayClient) async {
        var personalityName = "default"
        var gatewayName: String?
        var personaMDContent: String?

        if let result = try? await client.getConfig(key: "persona") {
            if let personality = result["personality"]?.stringValue, !personality.isEmpty {
                personalityName = personality
            }
            gatewayName = result["name"]?.stringValue
            personaMDContent = result["persona_md"]?.stringValue
        }

        if personaMDContent == nil,
           let result = try? await client.getConfig(key: "personality"),
           let value = result["value"]?.stringValue {
            personalityName = value
        }

        if gatewayName == nil,
           let result = try? await client.getConfig(key: "full"),
           let config = result["config"]?.dictionaryValue {
            let display = config["display"]?.dictionaryValue
            if let name = display?["agent_name"]?.stringValue, !name.isEmpty {
                gatewayName = name
            }
        }

        var persona = derivePersona(
            personalityName: personalityName,
            gatewayName: gatewayName,
            personaMD: personaMDContent
        )
        persona.isAgentDefault = true
        persona.isBuiltIn = true

        activePersona = persona
    }

    // MARK: - Persona Derivation

    private func derivePersona(personalityName: String, gatewayName: String?, personaMD: String?) -> Persona {
        let md = personaMD?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !md.isEmpty {
            return personaFromMD(md, personalityName: personalityName, gatewayName: gatewayName)
        }

        return Persona(
            id: personalityName,
            name: gatewayName ?? personalityName.capitalized,
            tagline: "AI Assistant",
            symbolName: "sparkles",
            accentColorHex: "#5856D6",
            imagePath: nil,
            systemPromptSuffix: nil,
            isBuiltIn: true
        )
    }

    private func personaFromMD(_ md: String, personalityName: String, gatewayName: String?) -> Persona {
        let lines = md.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var name = gatewayName ?? personalityName.capitalized
        if gatewayName == nil, let first = lines.first {
            let cleaned = first
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty && cleaned.count < 60 { name = cleaned }
        }

        let body = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let tagline: String
        if let dotRange = body.range(of: ".") {
            tagline = String(body[body.startIndex..<dotRange.lowerBound])
        } else if body.count > 100 {
            tagline = String(body.prefix(100)) + "…"
        } else {
            tagline = body.isEmpty ? "AI Assistant" : body
        }

        return Persona(
            id: personalityName.isEmpty ? "gateway-persona" : personalityName,
            name: name,
            tagline: tagline,
            symbolName: "sparkles",
            accentColorHex: "#5856D6",
            imagePath: nil,
            systemPromptSuffix: md,
            isBuiltIn: true
        )
    }
}
