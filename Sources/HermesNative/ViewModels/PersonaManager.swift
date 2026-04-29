import SwiftUI
import Combine
import Foundation

/// Manages persona assets: loading from disk, selecting active persona,
/// and providing the current identity to the view layer.
@MainActor
final class PersonaManager: ObservableObject {
    /// All available personas (built-in + user-provided)
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
        // Start with default
        let savedID = UserDefaults.standard.string(forKey: Self.activePersonaKey)
        self.activePersona = Persona.defaultPersona

        loadPersonas()

        // Restore saved selection
        if let savedID, let match = personas.first(where: { $0.id == savedID }) {
            self.activePersona = match
        }
    }

    /// Reload personas from disk (call after adding/removing persona files)
    func loadPersonas() {
        var loaded = Persona.builtInPersonas

        // Scan personas directory for .json files
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
                // Use filename (without extension) as ID if not set
                if persona.id.isEmpty {
                    persona.id = file.deletingPathExtension().lastPathComponent
                }
                persona.isBuiltIn = false
                loaded.append(persona)
            }
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
}
