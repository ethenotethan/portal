import SwiftUI
import Foundation

enum AvatarState: String, CaseIterable {
    case idle
    case thinking
    case speaking
    case toolUse
    case error
}

/// A composable persona asset that gives the AI assistant a visual identity.
/// Auto-derived from gateway PERSONA.md + config.
struct Persona: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var tagline: String
    var symbolName: String
    var accentColorHex: String
    var imagePath: String?
    var systemPromptSuffix: String?
    var isBuiltIn: Bool
    var isAgentDefault: Bool = false

    var accentColor: Color { Color(hex: accentColorHex) ?? .accentColor }

    /// True when this persona has a usable uploaded avatar image on disk.
    /// Custom images and identicons are self-contained pictures; the SF Symbol
    /// path is the last-resort fallback for built-in personas with neither.
    internal var hasCustomImage: Bool {
        guard let path = imagePath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The plain avatar glyph, unadorned. Resolution order:
    /// 1. uploaded image (`imagePath`) — the user's own picture,
    /// 2. deterministic identicon seeded from `id` — for harness personas that
    ///    have no uploaded picture (a stable, unique face per harness),
    /// 3. the SF Symbol — the built-in Portal persona keeps its glyph.
    @ViewBuilder
    var avatar: some View {
        if hasCustomImage, let path = imagePath, let image = PersonaImage.load(path: path) {
            image
                .resizable()
                .scaledToFill()
        } else if usesIdenticon {
            IdenticonView(seed: id)
        } else {
            Image(systemName: symbolName)
        }
    }

    /// Harness-derived personas (not the built-in Portal glyph) show an
    /// identicon when they have no uploaded image, so every harness reads as a
    /// distinct face rather than a shared `sparkles` symbol.
    private var usesIdenticon: Bool { !isBuiltIn }

    /// The avatar sized into a circle for chat bubbles / headers. An uploaded
    /// image or identicon fills the circle edge-to-edge; a symbol sits centered
    /// on the accent color.
    @ViewBuilder
    func bubbleAvatar(size: CGFloat = 28) -> some View {
        if hasCustomImage, let path = imagePath, let image = PersonaImage.load(path: path) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if usesIdenticon {
            IdenticonView(seed: id, size: size)
                .clipShape(Circle())
        } else {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(accentColor, in: Circle())
        }
    }

    static let defaultPersona = Persona(
        id: "portal", name: "Portal", tagline: "Your AI agent",
        symbolName: "sparkles", accentColorHex: "#007AFF",
        isBuiltIn: true
    )
}

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
