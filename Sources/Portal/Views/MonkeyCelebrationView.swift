import SceneKit
import SwiftUI

/// A monkey that rises into frame, raises a pistol at the viewer, says "good
/// job", lowers the pistol, shakes, and drops back out — in 3D.
///
/// Real SceneKit geometry with physically-based materials and three lights, not
/// a flat vector drawing. The first pass stacked SwiftUI shapes, and shapes have
/// no depth to light: everything landed in one plane, so the raised arm read as
/// a shape sliding sideways rather than a limb coming toward you.
///
/// The scene is built in code (`MonkeyScene`) rather than loaded from a
/// `.scn`/`.usdz`. `LottieCharacterView` shows what asset-backed characters cost
/// in this app — it walks five candidate bundle paths hunting for its JSON — and
/// a celebration that fails to appear because a file didn't resolve is worse than
/// one that draws plainly. Geometry in code always resolves.
///
/// Every pose comes from the `beat` the stage hands down, so this view holds no
/// timing of its own. The choreography is therefore a property of
/// `CelebrationBeat`, which is covered by tests, rather than of nested animation
/// completion handlers.
internal struct MonkeyCelebrationView: View {
    internal let beat: CelebrationBeat
    internal let message: String

    /// Built once and retained: rebuilding the scene graph on every beat would
    /// discard the in-flight SceneKit animations that make the motion smooth.
    @State private var scene = MonkeyScene()

    private static let stageSize = CGSize(width: 260, height: 300)

    internal var body: some View {
        VStack(spacing: 6) {
            speech
            SceneKitStage(scene: scene)
                .frame(width: Self.stageSize.width, height: Self.stageSize.height)
                // The rig animates its own rise and exit inside the scene, so
                // the SwiftUI layer must not also translate the view — the two
                // would compose into a double-height slide.
                .opacity(beat == .offstage ? 0 : 1)
        }
        .onAppear { scene.apply(beat) }
        .onChange(of: beat) { _, newValue in
            scene.apply(newValue)
        }
    }

    // MARK: - Speech

    /// The line stays 2D on purpose: extruded text at this size is unreadable,
    /// and a flat bubble over a lit character is how the medium usually does it.
    @ViewBuilder
    private var speech: some View {
        Text(message)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            )
            .scaleEffect(beat.isSpeaking ? 1 : 0.7, anchor: .bottom)
            .opacity(beat.isSpeaking ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: beat.isSpeaking)
    }
}

/// Hosts an `SCNScene` with a transparent background so the character sits over
/// the app rather than in a grey box.
///
/// Its own representable rather than SwiftUI's `SceneView` because that view
/// offers no way to turn the backing layer's opacity off — it composites an
/// opaque black rectangle, which over a chat transcript is a hole in the UI.
private struct SceneKitStage {
    internal let scene: MonkeyScene
}

#if os(macOS)
extension SceneKitStage: NSViewRepresentable {
    internal func makeNSView(context: Context) -> SCNView {
        makeView()
    }

    internal func updateNSView(_ view: SCNView, context: Context) {}
}
#else
extension SceneKitStage: UIViewRepresentable {
    internal func makeUIView(context: Context) -> SCNView {
        makeView()
    }

    internal func updateUIView(_ view: SCNView, context: Context) {}
}
#endif

extension SceneKitStage {
    /// `@MainActor` because it reads `MonkeyScene`'s nodes, which are
    /// main-actor-isolated. Both `makeNSView`/`makeUIView` are already called on
    /// the main actor, so this costs nothing at the call site.
    @MainActor
    fileprivate func makeView() -> SCNView {
        let view = SCNView()
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        // Transparent, so the celebration overlays the app instead of punching
        // an opaque rectangle through it.
        view.backgroundColor = .clear
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.isOpaque = false
        #endif
        view.antialiasingMode = .multisampling2X
        // No interaction: this is an overlay the user's clicks must pass
        // through, matching `.allowsHitTesting(false)` on the stage.
        view.allowsCameraControl = false
        // `rendersContinuously` false lets SceneKit idle between animations
        // rather than pinning a display link for the whole 3.4s.
        view.rendersContinuously = false
        return view
    }
}
