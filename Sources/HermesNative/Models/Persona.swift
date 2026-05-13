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
struct Persona: Codable, Identifiable, Equatable {
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

    @ViewBuilder
    var avatar: some View {
        Image(systemName: symbolName)
    }

    @ViewBuilder
    func bubbleAvatar(size: CGFloat = 28) -> some View {
        avatar
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(accentColor, in: Circle())
    }

    static let defaultPersona = Persona(
        id: "hermes", name: "Hermes", tagline: "Your AI agent",
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
