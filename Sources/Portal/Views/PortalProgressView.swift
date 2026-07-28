import SwiftUI

/// A macOS-safe alternative to ProgressView that avoids the
/// "Unable to render flattened version of PlatformViewRepresentableAdaptor<AppKitProgressView>"
/// diagnostic by using a SwiftUI-native spinner.
struct PortalProgressView: View {
    var label: String?

    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.accent, lineWidth: 2)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotation))
            if let label = label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
