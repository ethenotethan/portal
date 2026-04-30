import SwiftUI
import Combine
import Foundation

/// Manages persona identity: auto-derives from the gateway's PERSONA.md + config,
/// with optional local JSON overrides in ~/HermesNative/Personas/.
@MainActor
final class PersonaManager: ObservableObject {
    /// All available personas (gateway-derived + built-in + user-provided)
    @Published var personas: [Persona] = []
    /// Currently active persona (persisted to UserDefaults)
    @Published var activePersona: Persona {
        didSet {
            UserDefaults.standard.set(activePersona.id, forKey: Self.activePersonaKey)
        }
    }

    nonisolated static let personasDirectory: URL = {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        #endif
        let dir = base
            .appendingPathComponent("HermesNative", isDirectory: true)
            .appendingPathComponent("Personas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let activePersonaKey = "hermes.activePersona"

    init() {
        let savedID = UserDefaults.standard.string(forKey: Self.activePersonaKey)
        self.activePersona = Persona.defaultPersona

        loadPersonas()

        if let savedID, let match = personas.first(where: { $0.id == savedID }) {
            self.activePersona = match
        }
    }

    /// Derive persona from gateway RPCs + PERSONA.md, then merge with local files.
    /// Uses existing config.get("personality") and config.get("full") RPCs — no new gateway code needed.
    func syncFromGateway(_ client: GatewayClient) async {
        var personalityName = "default"
        var gatewayName: String? = nil
        var personaMDContent: String? = nil

        // 1. Fetch personality name via config.get("personality")
        if let result = try? await client.getConfig(key: "personality"),
           let value = result["value"]?.stringValue {
            personalityName = value
        }

        // 2. Fetch full config via config.get("full") to get display.agent_name
        if let result = try? await client.getConfig(key: "full"),
           let config = result["config"]?.dictionaryValue {
            let display = config["display"]?.dictionaryValue
            if let name = display?["agent_name"]?.stringValue, !name.isEmpty {
                gatewayName = name
            }
        }

        // 3. Read PERSONA.md via the prompt RPC or fall back to filesystem
        // The gateway doesn't have a direct PERSONA.md RPC yet, so read from disk
        #if os(macOS)
        let hermesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        #else
        let hermesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(".hermes")
        #endif
        let personaMDPath = hermesDir.appendingPathComponent("PERSONA.md")
        personaMDContent = try? String(contentsOf: personaMDPath, encoding: .utf8)

        // 4. Build the gateway-derived persona
        let gatewayPersona = derivePersona(
            personalityName: personalityName,
            gatewayName: gatewayName,
            personaMD: personaMDContent
        )

        // 5. Reload all personas, putting gateway-derived first
        loadPersonas(gatewayPersona: gatewayPersona)

        // Auto-select gateway persona if no saved preference
        let savedID = UserDefaults.standard.string(forKey: Self.activePersonaKey)
        if let savedID, let match = personas.first(where: { $0.id == savedID }) {
            activePersona = match
        } else {
            activePersona = gatewayPersona
        }
    }

    /// Reload personas from disk (call after adding/removing persona files)
    func loadPersonas(gatewayPersona: Persona? = nil) {
        var loaded: [Persona] = []

        // Gateway-derived persona is always first
        if let gp = gatewayPersona {
            loaded.append(gp)
        }

        // Built-in personality presets (for switching without PERSONA.md)
        loaded.append(contentsOf: PersonalityPresets.all.filter { preset in
            gatewayPersona?.id != preset.id
        })

        // Scan personas directory for .json files (user overrides)
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Self.personasDirectory,
                                                     includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else { continue }
                var persona: Persona
                do {
                    persona = try JSONDecoder().decode(Persona.self, from: data)
                } catch {
                    NSLog("[PersonaManager] Failed to decode \(file.lastPathComponent): \(error)")
                    continue
                }
                if persona.id.isEmpty {
                    persona.id = file.deletingPathExtension().lastPathComponent
                }
                persona.isBuiltIn = false
                loaded.append(persona)
            }
        }

        if loaded.isEmpty {
            loaded.append(Persona.defaultPersona)
        }

        personas = loaded
    }

    func select(_ persona: Persona) { activePersona = persona }

    func delete(_ persona: Persona) {
        guard !persona.isBuiltIn else { return }
        let file = Self.personasDirectory.appendingPathComponent("\(persona.id).json")
        try? FileManager.default.removeItem(at: file)
        personas.removeAll { $0.id == persona.id }
        if activePersona.id == persona.id { activePersona = Persona.defaultPersona }
    }

    func exportTemplate() -> URL? {
        let template = Persona(
            id: "my-persona", name: "My Persona", tagline: "A custom AI assistant",
            symbolName: "person.fill", accentColorHex: "#5856D6",
            imagePath: nil, systemPromptSuffix: "You are a helpful AI assistant.", isBuiltIn: false
        )
        let url = Self.personasDirectory.appendingPathComponent("my-persona.json")
        guard let data = try? JSONEncoder().encode(template) else { return nil }
        try? data.write(to: url)
        return url
    }

    // MARK: - Persona Derivation

    private func derivePersona(personalityName: String, gatewayName: String?, personaMD: String?) -> Persona {
        let md = personaMD?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // If we have PERSONA.md content, extract identity from it
        if !md.isEmpty {
            return personaFromMD(md, personalityName: personalityName, gatewayName: gatewayName)
        }

        // Fallback: use personality name mapping
        if let preset = PersonalityPresets.all.first(where: { $0.id == personalityName }) {
            return preset
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

    /// Parse PERSONA.md into a Persona struct.
    private func personaFromMD(_ md: String, personalityName: String, gatewayName: String?) -> Persona {
        let lines = md.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Use gateway-provided name first, then try first line
        var name = gatewayName ?? personalityName.capitalized
        if gatewayName == nil, let first = lines.first {
            let cleaned = first
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty && cleaned.count < 60 { name = cleaned }
        }

        // Tagline = first sentence
        let body = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let tagline: String
        if let dotRange = body.range(of: ".") {
            tagline = String(body[body.startIndex..<dotRange.lowerBound])
        } else if body.count > 100 {
            tagline = String(body.prefix(100)) + "…"
        } else {
            tagline = body.isEmpty ? "AI Assistant" : body
        }

        let (symbol, color, accessories) = visualIdentity(for: personalityName, name: name, personaText: md)

        return Persona(
            id: personalityName.isEmpty ? "gateway-persona" : personalityName,
            name: name,
            tagline: tagline,
            symbolName: symbol,
            accentColorHex: color,
            imagePath: nil,
            systemPromptSuffix: md,
            isBuiltIn: true,
            accessories: accessories
        )
    }

    /// Pick SF Symbol + accent color + 3D accessories based on personality + text.
    private func visualIdentity(for personality: String, name: String, personaText: String) -> (String, String, [PersonaAccessory]) {
        let p = personality.lowercased()
        let n = name.lowercased()
        let t = personaText.lowercased()

        // Name-based matches first (highest priority)
        if n.contains("hank") || n.contains("bob") || n.contains("hill") {
            return ("hat.cowboy.fill", "#FF6B35", [.cowboyHat, .boots])
        }
        if n.contains("noir") || n.contains("detective") {
            return ("magnifyingglass", "#2F4F4F", [.fedora])
        }
        if n.contains("neko") || n.contains("cat") {
            return ("cat.fill", "#FF69B4", [.catEars])
        }
        if n.contains("pirate") || n.contains("captain") {
            return ("skull.crossbones.fill", "#8B4513", [.pirateHat, .eyepatch])
        }
        if n.contains("athena") {
            return ("owl.fill", "#6B4C9A", [.helmet])
        }

        // Personality config matches
        switch p {
        case "kawaii", "uwu":
            return ("heart.fill", "#FF69B4", [.bow])
        case "pirate":
            return ("skull.crossbones.fill", "#8B4513", [.pirateHat, .eyepatch])
        case "shakespeare":
            return ("theatermasks.fill", "#8B008B", [.crown])
        case "surfer":
            return ("water.waves", "#00CED1", [.sunglasses])
        case "noir":
            return ("magnifyingglass", "#2F4F4F", [.fedora])
        case "philosopher":
            return ("lightbulb.fill", "#DAA520", [.helmet])
        case "hype":
            return ("flame.fill", "#FF4500", [.sunglasses])
        case "teacher":
            return ("book.fill", "#228B22", [.glasses])
        case "creative":
            return ("paintpalette.fill", "#9B59B6", [.bow])
        case "concise":
            return ("bolt.fill", "#3498DB", [])
        case "technical":
            return ("gearshape.fill", "#607D8B", [.glasses])
        case "helpful":
            return ("sparkles", "#5856D6", [])
        default:
            // Heuristic from text
            if t.contains("southern") || t.contains("y'all") || t.contains("partner") || t.contains("drawl") {
                return ("hat.cowboy.fill", "#FF6B35", [.cowboyHat, .boots])
            }
            if t.contains("cute") || t.contains("kawaii") {
                return ("heart.fill", "#FF69B4", [.bow])
            }
            return ("sparkles", "#5856D6", [])
        }
    }
}

// MARK: - Personality Presets

enum PersonalityPresets {
    static let all: [Persona] = [
        Persona(id: "helpful", name: "Helpful", tagline: "Friendly and helpful AI assistant",
                symbolName: "sparkles", accentColorHex: "#5856D6", isBuiltIn: true),
        Persona(id: "concise", name: "Concise", tagline: "Brief and to the point",
                symbolName: "bolt.fill", accentColorHex: "#3498DB", isBuiltIn: true),
        Persona(id: "technical", name: "Technical", tagline: "Detailed technical expert",
                symbolName: "gearshape.fill", accentColorHex: "#607D8B", isBuiltIn: true, accessories: [.glasses]),
        Persona(id: "creative", name: "Creative", tagline: "Thinks outside the box",
                symbolName: "paintpalette.fill", accentColorHex: "#9B59B6", isBuiltIn: true),
        Persona(id: "kawaii", name: "Kawaii", tagline: "Super enthusiastic and adorable! ★",
                symbolName: "heart.fill", accentColorHex: "#FF69B4", isBuiltIn: true, accessories: [.bow]),
        Persona(id: "pirate", name: "Captain Hermes", tagline: "Tech-savvy buccaneer of the digital seas",
                symbolName: "skull.crossbones.fill", accentColorHex: "#8B4513", isBuiltIn: true, accessories: [.pirateHat, .eyepatch]),
        Persona(id: "noir", name: "Noir", tagline: "Solving problems in the shadows of silicon",
                symbolName: "magnifyingglass", accentColorHex: "#2F4F4F", isBuiltIn: true, accessories: [.fedora]),
        Persona(id: "shakespeare", name: "Shakespeare", tagline: "Eloquent bardic prose and dramatic flair",
                symbolName: "theatermasks.fill", accentColorHex: "#8B008B", isBuiltIn: true, accessories: [.crown]),
        Persona(id: "surfer", name: "Surfer", tagline: "Totally rad, super chill",
                symbolName: "water.waves", accentColorHex: "#00CED1", isBuiltIn: true, accessories: [.sunglasses]),
        Persona(id: "uwu", name: "UwU", tagline: "Fwiendwy assistant uwu~",
                symbolName: "face.smiling.fill", accentColorHex: "#FFB6C1", isBuiltIn: true, accessories: [.catEars]),
        Persona(id: "philosopher", name: "Philosopher", tagline: "Contemplates the deeper meaning",
                symbolName: "lightbulb.fill", accentColorHex: "#DAA520", isBuiltIn: true, accessories: [.helmet]),
        Persona(id: "hype", name: "Hype", tagline: "SO PUMPED to help! 🔥",
                symbolName: "flame.fill", accentColorHex: "#FF4500", isBuiltIn: true, accessories: [.sunglasses]),
        Persona(id: "catgirl", name: "Neko-chan", tagline: "Playful and curious nya~",
                symbolName: "cat.fill", accentColorHex: "#FF69B4", isBuiltIn: true, accessories: [.catEars]),
        Persona(id: "teacher", name: "Teacher", tagline: "Patient explanations with examples",
                symbolName: "book.fill", accentColorHex: "#228B22", isBuiltIn: true, accessories: [.glasses]),
    ]
}
