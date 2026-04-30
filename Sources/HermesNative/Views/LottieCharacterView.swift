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
        LottieRepresentableWrapper(
            fileName: expression.fileName,
            speed: expression.speed,
            loopMode: expression.loopMode
        )
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Cross-platform Lottie representable

/// Resolves the Lottie animation with fallback loading.
/// Tries: 1) Bundle.module (SPM resource bundle)
///        2) Bundle.main (Xcode build)
///        3) Source tree relative to executable (fresh swift run)
///        4) CWD-relative path
private func loadLottieAnimation(fileName: String) -> LottieAnimation? {
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
    #if os(macOS)
    let exeURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    #else
    let exeURL = Bundle.main.executableURL ?? Bundle.main.bundleURL
    #endif
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

#if os(macOS)
struct LottieRepresentableWrapper: NSViewRepresentable {
    let fileName: String
    let speed: CGFloat
    let loopMode: LottieLoopMode

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.animation = loadLottieAnimation(fileName: fileName)
        view.animationSpeed = speed
        view.loopMode = loopMode
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        view.play()
        return view
    }

    func updateNSView(_ nsView: LottieAnimationView, context: Context) {
        let newAnim = loadLottieAnimation(fileName: fileName)
        if nsView.animation == nil || newAnim != nil {
            nsView.animation = newAnim
        }
        nsView.animationSpeed = speed
        nsView.loopMode = loopMode
        nsView.play()
    }
}
#else
struct LottieRepresentableWrapper: UIViewRepresentable {
    let fileName: String
    let speed: CGFloat
    let loopMode: LottieLoopMode

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.animation = loadLottieAnimation(fileName: fileName)
        view.animationSpeed = speed
        view.loopMode = loopMode
        view.contentMode = .scaleAspectFit
        view.backgroundBehavior = .pauseAndRestore
        view.play()
        return view
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {
        let newAnim = loadLottieAnimation(fileName: fileName)
        if uiView.animation == nil || newAnim != nil {
            uiView.animation = newAnim
        }
        uiView.animationSpeed = speed
        uiView.loopMode = loopMode
        uiView.play()
    }
}
#endif
