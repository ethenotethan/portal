import SwiftUI
import SceneKit

/// SwiftUI view wrapping the 3D avatar SceneKit scene.
/// Binds to ChatViewModel state to drive avatar animations.
struct Avatar3DView: View {
    let state: AvatarState
    let accentColorHex: String
    let accessories: [PersonaAccessory]
    let size: CGFloat

    @State private var scene: AvatarScene?

    init(state: AvatarState, accentColorHex: String = "#5856D6",
         accessories: [PersonaAccessory] = [], size: CGFloat = 120) {
        self.state = state
        self.accentColorHex = accentColorHex
        self.accessories = accessories
        self.size = size
    }

    var body: some View {
        Group {
            if let scene {
                SceneView(scene: scene)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                ProgressView()
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            let s = AvatarScene()
            s.accentColor = nsColor(fromHex: accentColorHex)
            s.accessories = accessories
            scene = s
        }
        .onChange(of: state) { _, newState in
            scene?.transition(to: newState)
        }
        .onChange(of: accentColorHex) { _, newHex in
            scene?.accentColor = nsColor(fromHex: newHex)
        }
        .onChange(of: accessories) { _, newAccessories in
            scene?.accessories = newAccessories
        }
    }
}

/// Small label showing the current avatar state
struct AvatarStateLabel: View {
    let state: AvatarState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .thinking: .yellow
        case .speaking: .green
        case .toolUse: .blue
        case .error: .red
        }
    }

    private var label: String {
        switch state {
        case .idle: "Idle"
        case .thinking: "Thinking…"
        case .speaking: "Speaking"
        case .toolUse: "Using tools"
        case .error: "Error"
        }
    }
}

// MARK: - Platform Color Hex Helper

private func nsColor(fromHex hex: String) -> PlatformColor {
    let h = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return PlatformColor(red: 0.5, green: 0, blue: 0.5, alpha: 1) }
    return PlatformColor(
        red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
        green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
        blue: CGFloat(rgb & 0x0000FF) / 255.0,
        alpha: 1.0
    )
}
