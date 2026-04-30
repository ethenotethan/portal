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

    /// Resolves the Lottie animation with fallback loading.
    /// Tries: 1) Bundle.module (SPM resource bundle)
    ///        2) Bundle.main (Xcode build)
    ///        3) Source tree relative to executable (fresh swift run)
    ///        4) CWD-relative path
    private func loadAnimation() -> LottieAnimation? {
        // 1. SPM resource bundle (works on most builds)
        if let url = Bundle.module.resourceURL?.appendingPathComponent("Lottie/\(fileName).json"),
           let animation = LottieAnimation.filepath(url.path) {
            return animation
        }

        // 2. Direct Bundle.module named lookup
        if let animation = LottieAnimation.named(fileName, bundle: .module) {
            return animation
        }

        // 3. Bundle.main (Xcode builds)
        if let animation = LottieAnimation.named(fileName, bundle: .main) {
            return animation
        }

        // 4. Source tree: look relative to the executable for Sources/.../Resources/Lottie/
        let exeURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let buildDir = exeURL.deletingLastPathComponent()
        let possiblePaths = [
            buildDir.appendingPathComponent("../Sources/HermesNative/Resources/Lottie/\(fileName).json"),
            buildDir.appendingPathComponent("../../Sources/HermesNative/Resources/Lottie/\(fileName).json"),
            // Also try the SPM resource bundle sitting next to the exe
            buildDir.appendingPathComponent("HermesNative_HermesNative.bundle/Lottie/\(fileName).json"),
        ]
        for path in possiblePaths {
            if let animation = LottieAnimation.filepath(path.path) {
                return animation
            }
        }

        // 5. CWD-relative
        let cwd = FileManager.default.currentDirectoryPath
        let cwdPath = "\(cwd)/Sources/HermesNative/Resources/Lottie/\(fileName).json"
        if let animation = LottieAnimation.filepath(cwdPath) {
            return animation
        }

        return nil
    }

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.animation = loadAnimation()
        view.animationSpeed = speed
        view.loopMode = loopMode
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        view.play()
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        let newAnim = loadAnimation()
        // Only swap animation if the file changed (different expression)
        if nsView.animation == nil || newAnim != nil {
            nsView.animation = newAnim
        }
        nsView.animationSpeed = speed
        nsView.loopMode = loopMode
        nsView.play()
    }
}
