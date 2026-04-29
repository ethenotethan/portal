import SwiftUI
import Foundation

/// 3D accessory that can be attached to the avatar — persona-specific.
enum PersonaAccessory: String, Codable, CaseIterable {
    case cowboyHat
    case fedora
    case pirateHat
    case crown
    case helmet       // Greek/Athena
    case catEars
    case glasses
    case sunglasses
    case eyepatch
    case bow          // kawaii hair bow
    case boots
}

/// A composable persona asset that gives the AI assistant a visual identity.
/// Auto-derived from gateway PERSONA.md + config, or from local JSON overrides.
struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var tagline: String
    var symbolName: String
    var accentColorHex: String
    var imagePath: String?
    var systemPromptSuffix: String?
    var isBuiltIn: Bool
    /// 3D accessories rendered on the avatar — persona-specific identity
    var accessories: [PersonaAccessory] = []

    // MARK: - Computed

    var accentColor: Color { Color(hex: accentColorHex) ?? .accentColor }

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
        if path.hasPrefix("/") { return NSImage(contentsOfFile: path) }
        let personasDir = PersonaManager.personasDirectory
        let absolute = personasDir.appendingPathComponent(path).path
        return NSImage(contentsOfFile: absolute)
    }

    // MARK: - Defaults

    static let defaultPersona = Persona(
        id: "hermes", name: "Hermes", tagline: "Your AI agent",
        symbolName: "sparkles", accentColorHex: "#007AFF",
        isBuiltIn: true, accessories: []
    )
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
