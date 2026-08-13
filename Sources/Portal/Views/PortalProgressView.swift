import SwiftUI

/// A macOS-safe alternative to ProgressView that avoids the
/// "Unable to render flattened version of PlatformViewRepresentableAdaptor<AppKitProgressView>"
/// diagnostic by using a SwiftUI-native spinner.
struct PortalProgressView: View {
    var label: String?

    @State private var isSpinning = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Theme.accent, lineWidth: 2)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                // Scoped to this one value, NOT `withAnimation` in `onAppear`.
                // `withAnimation` sets the animation on the whole transaction,
                // so every change flushed alongside it inherits the curve — and
                // this curve is `repeatForever`, which never completes. Any
                // ancestor frame that happened to change in the same update
                // therefore animated forever, keeping SwiftUI's animator
                // permanently scheduled: sampled live at 100% CPU with
                // `AnimatableFrameAttribute.updateValue` and
                // `AnimatorState.nextUpdate` on the hot path, feeding a fresh
                // layout pass every tick. A spinner must not be able to put the
                // rest of the window into perpetual animation.
                //
                // This is also the form the other four `repeatForever` sites in
                // the app already use (FeedView, SessionListView,
                // CentaurWorkflowsView) — this was the odd one out.
                .animation(
                    .linear(duration: 0.8).repeatForever(autoreverses: false),
                    value: isSpinning
                )
            if let label = label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { isSpinning = true }
    }
}
