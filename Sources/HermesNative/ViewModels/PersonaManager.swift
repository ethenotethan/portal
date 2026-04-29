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
        let dir = FileManager.default.homeDirectoryForCurrentUser
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

    /// Derive persona from gateway config + PERSONA.md, then merge with local files.
    /// Call this after the WS connection is established.
    func syncFromGateway(_ client: GatewayClient) async {
        var personalityName = "default"
        var personaMDContent: String? = nil

        // 1. Fetch active personality from gateway config
        if let result = try? await client.getConfig(key: "personality"),
           let value = result["value"]?.stringValue {
            personalityName = value
        }

        // 2. Read PERSONA.md from ~/.hermes/
        let personaMDPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/PERSONA.md")
        personaMDContent = try? String(contentsOf: personaMDPath, encoding: .utf8)

        // 3. Build the gateway-derived persona
        let gatewayPersona = derivePersona(
            personalityName: personalityName,
            personaMD: personaMDContent
        )

        // 4. Reload all personas, putting gateway-derived first
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
            // Don't duplicate if gateway already provided this personality
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

        // Fallback default if nothing else
        if loaded.isEmpty {
            loaded.append(Persona.defaultPersona)
        }

        personas = loaded
    }

    /// Switch to a different persona
    func select(_ persona: Persona) {
        activePersona = persona
    }

    /// Delete a custom (non-built-in) persona
    func delete(_ persona: Persona) {
        guard !persona.isBuiltIn else { return }
        let file = Self.personasDirectory.appendingPathComponent("\(persona.id).json")
        try? FileManager.default.removeItem(at: file)
        personas.removeAll { $0.id == persona.id }
        if activePersona.id == persona.id {
            activePersona = Persona.defaultPersona
        }
    }

    /// Export a persona template to the personas directory
    func exportTemplate() -> URL? {
        let template = Persona(
            id: "my-persona",
            name: "My Persona",
            tagline: "A custom AI assistant",
            symbolName: "person.fill",
            accentColorHex: "#5856D6",
            imagePath: nil,
            systemPromptSuffix: "You are a helpful AI assistant.",
            isBuiltIn: false
        )
        let url = Self.personasDirectory.appendingPathComponent("my-persona.json")
        guard let data = try? JSONEncoder().encode(template) else { return nil }
        try? data.write(to: url)
        return url
    }

    // MARK: - Persona Derivation

    /// Derive a Persona struct from gateway personality name + PERSONA.md content.
    private func derivePersona(personalityName: String, personaMD: String?) -> Persona {
        // If we have PERSONA.md content, extract identity from it
        if let md = personaMD, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return personaFromMD(md, personalityName: personalityName)
        }

        // Fallback: use personality name mapping
        if let preset = PersonalityPresets.all.first(where: { $0.id == personalityName }) {
            return preset
        }

        // Final fallback: generic
        return Persona(
            id: personalityName,
            name: personalityName.capitalized,
            tagline: "AI Assistant",
            symbolName: "sparkles",
            accentColorHex: "#5856D6",
            imagePath: nil,
            systemPromptSuffix: nil,
            isBuiltIn: true
        )
    }

    /// Parse PERSONA.md into a Persona struct.
    /// First non-empty line → name, rest → tagline (first sentence) + systemPromptSuffix
    private func personaFromMD(_ md: String, personalityName: String) -> Persona {
        let lines = md.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Extract name from first meaningful line
        var name = personalityName.capitalized
        if let first = lines.first {
            let cleaned = first
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty && cleaned.count < 60 {
                name = cleaned
            }
        }

        // Tagline = first sentence of the content (up to first period or 100 chars)
        let body = lines.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let tagline: String
        if let dotRange = body.range(of: ".") {
            tagline = String(body[body.startIndex..<dotRange.lowerBound])
        } else if body.count > 100 {
            tagline = String(body.prefix(100)) + "…"
        } else {
            tagline = body.isEmpty ? "AI Assistant" : body
        }

        // Pick visual identity based on personality keywords
        let (symbol, color) = visualIdentity(for: personalityName, personaText: md)

        return Persona(
            id: personalityName.isEmpty ? "gateway-persona" : personalityName,
            name: name,
            tagline: tagline,
            symbolName: symbol,
            accentColorHex: color,
            imagePath: nil,
            systemPromptSuffix: md,
            isBuiltIn: true
        )
    }

    /// Heuristic: pick SF Symbol + accent color based on personality keywords.
    private func visualIdentity(for personality: String, personaText: String) -> (String, String) {
        let p = personality.lowercased()
        let t = personaText.lowercased()

        switch p {
        case "kawaii", "uwu", "catgirl":
            return ("heart.fill", "#FF69B4")
        case "pirate":
            return ("skull.crossbones.fill", "#8B4513")
        case "shakespeare":
            return ("theatermasks.fill", "#8B008B")
        case "surfer":
            return ("water.waves", "#00CED1")
        case "noir":
            return ("magnifyingglass", "#2F4F4F")
        case "philosopher":
            return ("lightbulb.fill", "#DAA520")
        case "hype":
            return ("flame.fill", "#FF4500")
        case "teacher":
            return ("book.fill", "#228B22")
        case "creative":
            return ("paintpalette.fill", "#9B59B6")
        case "concise":
            return ("bolt.fill", "#3498DB")
        case "technical":
            return ("gearshape.fill", "#607D8B")
        case "helpful":
            return ("sparkles", "#5856D6")
        default:
            // Heuristic from text content
            if t.contains("southern") || t.contains("y'all") || t.contains("partner") {
                return ("hat.cowboy.fill", "#FF6B35")
            }
            if t.contains("cute") || t.contains("kawaii") || t.contains("♥") {
                return ("heart.fill", "#FF69B4")
            }
            if t.contains("pirate") || t.contains("arr") {
                return ("skull.crossbones.fill", "#8B4513")
            }
            if t.contains("detective") || t.contains("noir") {
                return ("magnifyingglass", "#2F4F4F")
            }
            if t.contains("research") || t.contains("paper") {
                return ("atom", "#5856D6")
            }
            return ("sparkles", "#5856D6")
        }
    }
}

// MARK: - Personality Presets

/// Built-in personality presets matching the gateway's config.yaml personalities.
enum PersonalityPresets {
    static let all: [Persona] = [
        Persona(id: "helpful", name: "Helpful", tagline: "Friendly and helpful AI assistant",
                symbolName: "sparkles", accentColorHex: "#5856D6", isBuiltIn: true),
        Persona(id: "concise", name: "Concise", tagline: "Brief and to the point",
                symbolName: "bolt.fill", accentColorHex: "#3498DB", isBuiltIn: true),
        Persona(id: "technical", name: "Technical", tagline: "Detailed technical expert",
                symbolName: "gearshape.fill", accentColorHex: "#607D8B", isBuiltIn: true),
        Persona(id: "creative", name: "Creative", tagline: "Thinks outside the box",
                symbolName: "paintpalette.fill", accentColorHex: "#9B59B6", isBuiltIn: true),
        Persona(id: "kawaii", name: "Kawaii", tagline: "Super enthusiastic and adorable! ★",
                symbolName: "heart.fill", accentColorHex: "#FF69B4", isBuiltIn: true),
        Persona(id: "pirate", name: "Captain Hermes", tagline: "Tech-savvy buccaneer of the digital seas",
                symbolName: "skull.crossbones.fill", accentColorHex: "#8B4513", isBuiltIn: true),
        Persona(id: "noir", name: "Noir", tagline: "Solving problems in the shadows of silicon",
                symbolName: "magnifyingglass", accentColorHex: "#2F4F4F", isBuiltIn: true),
        Persona(id: "shakespeare", name: "Shakespeare", tagline: "Eloquent bardic prose and dramatic flair",
                symbolName: "theatermasks.fill", accentColorHex: "#8B008B", isBuiltIn: true),
        Persona(id: "surfer", name: "Surfer", tagline: "Totally rad, super chill",
                symbolName: "water.waves", accentColorHex: "#00CED1", isBuiltIn: true),
        Persona(id: "uwu", name: "UwU", tagline: "Fwiendwy assistant uwu~",
                symbolName: "face.smiling.fill", accentColorHex: "#FFB6C1", isBuiltIn: true),
        Persona(id: "philosopher", name: "Philosopher", tagline: "Contemplates the deeper meaning",
                symbolName: "lightbulb.fill", accentColorHex: "#DAA520", isBuiltIn: true),
        Persona(id: "hype", name: "Hype", tagline: "SO PUMPED to help! 🔥",
                symbolName: "flame.fill", accentColorHex: "#FF4500", isBuiltIn: true),
        Persona(id: "catgirl", name: "Neko-chan", tagline: "Playful and curious nya~",
                symbolName: "cat.fill", accentColorHex: "#FF69B4", isBuiltIn: true),
        Persona(id: "teacher", name: "Teacher", tagline: "Patient explanations with examples",
                symbolName: "book.fill", accentColorHex: "#228B22", isBuiltIn: true),
    ]
}
