import SwiftUI
import Lottie

/// Expression states for the animated character.
enum CharacterExpression: String, CaseIterable {
    case idle
    case thinking
    case happy
    case confused

    /// Lottie animation file name (without extension) in Resources/Lottie/
    var fileName: String { rawValue }

    /// Playback speed per expression
    var speed: CGFloat {
        switch self {
        case .idle:     1.0
        case .thinking: 0.6
        case .happy:    1.4
        case .confused: 0.8
        }
    }

    /// Loop mode per expression
    var loopMode: LottieLoopMode {
        .loop
    }
}

/// SwiftUI view that renders an animated Lottie character
/// with swappable expression states.
struct LottieCharacterView: View {
    let expression: CharacterExpression
    let size: CGSize

    var body: some View {
        LottieAnimationViewRepresentable(
            fileName: expression.fileName,
            speed: expression.speed,
            loopMode: expression.loopMode
        )
        .frame(width: size.width, height: size.height)
    }
}

/// NSViewRepresentable wrapper for LottieAnimationView.
/// Handles animation loading, playback, and expression transitions.
struct LottieAnimationViewRepresentable: NSViewRepresentable {
    let fileName: String
    let speed: CGFloat
    let loopMode: LottieLoopMode

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.animation = LottieAnimation.named(fileName)
        view.animationSpeed = speed
        view.loopMode = loopMode
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        view.play()
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        // Always reload — LottieAnimation doesn't expose a name property,
        // and expression changes are infrequent enough that re-loading is fine.
        nsView.animation = LottieAnimation.named(fileName)
        nsView.animationSpeed = speed
        nsView.loopMode = loopMode
        nsView.play()
    }
}
