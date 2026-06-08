import SwiftUI

/// A macOS-safe alternative to ProgressView that avoids the
/// "Unable to render flattened version of PlatformViewRepresentableAdaptor<AppKitProgressView>"
/// diagnostic by using a SwiftUI-native spinner instead of the AppKit NSProgressIndicator.
struct HermesProgressView: View {
    var label: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.accent, lineWidth: 2)
                .frame(width: 14, height: 14)
                .phaseAnimator([0, 360]) { view, phase in
                    view.rotationEffect(.degrees(phase))
                } animation: { _ in
                    .linear(duration: 0.8).repeatForever(autoreverses: false)
                }
            if let label = label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
