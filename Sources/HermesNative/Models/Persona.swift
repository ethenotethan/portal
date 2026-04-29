import SwiftUI
import Foundation

/// A composable persona asset that gives the AI assistant a visual identity.
/// Personas are loaded from JSON files in ~/HermesNative/Personas/ or bundled defaults.
/// Anyone can create a persona by dropping a .json file in the personas directory.
struct Persona: Codable, Identifiable, Equatable {
    /// Unique identifier (filename without extension)
    var id: String
    /// Display name shown in message bubbles, toolbar, input placeholder
    var name: String
    /// Short tagline shown in persona picker
    var tagline: String
    /// SF Symbol name for the avatar (used if imagePath is nil)
    var symbolName: String
    /// Accent color as hex string (e.g. "#FF6B35")
    var accentColorHex: String
    /// Optional path to a custom avatar image (relative to persona file or absolute)
    var imagePath: String?
    /// Optional system prompt snippet injected on session creation
    var systemPromptSuffix: String?
    /// Whether this is a built-in persona (can't be deleted)
    var isBuiltIn: Bool

    // MARK: - Computed

    /// The resolved accent color
    var accentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }

    /// The avatar view — uses custom image if available, otherwise SF Symbol
    @ViewBuilder
    var avatar: some View {
        if let imagePath, let nsImage = loadImage(at: imagePath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: symbolName)
        }
    }

    /// Circular avatar suitable for message bubbles
    @ViewBuilder
    func bubbleAvatar(size: CGFloat = 28) -> some View {
        avatar
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(accentColor, in: Circle())
    }

    // MARK: - Image Loading

    private func loadImage(at path: String) -> NSImage? {
        // Try absolute path first
        if path.hasPrefix("/") {
            return NSImage(contentsOfFile: path)
        }
        // Try relative to personas directory
        let personasDir = PersonaManager.personasDirectory
        let absolute = personasDir.appendingPathComponent(path).path
        return NSImage(contentsOfFile: absolute)
    }

    // MARK: - Defaults

    static let defaultPersona = Persona(
        id: "hermes",
        name: "Hermes",
        tagline: "Your AI agent",
        symbolName: "sparkles",
        accentColorHex: "#007AFF",
        isBuiltIn: true
    )

    static let hankBob = Persona(
        id: "hank-bob",
        name: "Hank Bob",
        tagline: "Down-home AI wrangler",
        symbolName: "hat.cowboy.fill",
        accentColorHex: "#FF6B35",
        systemPromptSuffix: "You are Hank Bob, a friendly, down-to-earth AI assistant with a Southern charm. You speak plainly and honestly, with occasional colloquialisms, but you're sharp as a tack when it comes to technical work. You call people 'partner' and 'friend' naturally.",
        isBuiltIn: true
    )

    static let athena = Persona(
        id: "athena",
        name: "Athena",
        tagline: "Strategic AI advisor",
        symbolName: "owl.fill",
        accentColorHex: "#6B4C9A",
        systemPromptSuffix: "You are Athena, a wise and strategic AI advisor. You think carefully before responding, provide structured analysis, and draw on deep knowledge across domains. Your tone is measured, insightful, and occasionally witty.",
        isBuiltIn: true
    )

    static let nova = Persona(
        id: "nova",
        name: "Nova",
        tagline: "Creative AI companion",
        symbolName: "star.fill",
        accentColorHex: "#FF375F",
        systemPromptSuffix: "You are Nova, a creative and energetic AI companion. You bring enthusiasm and fresh perspectives to every conversation. You love brainstorming, exploring unconventional ideas, and finding elegant solutions.",
        isBuiltIn: true
    )

    static let builtInPersonas: [Persona] = [defaultPersona, hankBob, athena, nova]
}

// MARK: - Color Hex Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}
