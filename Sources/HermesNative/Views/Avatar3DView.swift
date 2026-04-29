import SwiftUI
import SceneKit

/// SwiftUI view wrapping the 3D avatar SceneKit scene.
/// Binds to ChatViewModel state to drive avatar animations.
struct Avatar3DView: View {
    let state: AvatarState
    let accentColorHex: String
    let size: CGFloat

    @State private var scene: AvatarScene?

    init(state: AvatarState, accentColorHex: String = "#5856D6", size: CGFloat = 120) {
        self.state = state
        self.accentColorHex = accentColorHex
        self.size = size
    }

    var body: some View {
        Group {
            if let scene {
                SceneView(
                    scene: scene,
                    options: [.allowsCameraControl, .autoenablesDefaultLighting]
                )
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                ProgressView()
                    .frame(width: size, height: size)
            }
        }
        .onAppear {
            let s = AvatarScene()
            s.accentColor = NSColor(hex: accentColorHex) ?? .systemPurple
            scene = s
        }
        .onChange(of: state) { _, newState in
            scene?.transition(to: newState)
        }
        .onChange(of: accentColorHex) { _, newHex in
            scene?.accentColor = NSColor(hex: newHex) ?? .systemPurple
        }
    }
}

// MARK: - State Label

/// Small label showing the current avatar state (for debugging / overlay)
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
