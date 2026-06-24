import SwiftUI

// MARK: - Perf Overlay HUD
//
// A floating, draggable heads-up display showing live memory footprint, CPU%,
// thread count, and live-instance counts from the LeakTracker. Debug-only.
//
// Toggle visibility via PerfOverlayState.shared.isVisible (bind it to a
// keyboard shortcut, a settings toggle, or set true under `--perf`). Attach to
// the root view with `.perfOverlay()`.

/// Observable visibility/state for the perf overlay.
@MainActor
final class PerfOverlayState: ObservableObject {
    static let shared = PerfOverlayState()
    @Published var isVisible: Bool

    private init() {
        // Auto-show when launched with --perf so you see numbers immediately.
        self.isVisible = perfInstrumentationEnabled
    }

    func toggle() { isVisible.toggle() }
}

#if DEBUG
/// The HUD content. Reads from PerfSampler.shared; the sampler must be started
/// (PerfInstrumentation.bootstrap or PerfSampler.shared.start()).
struct PerfOverlayView: View {
    @ObservedObject private var sampler = PerfSampler.shared
    @ObservedObject private var state = PerfOverlayState.shared
    @State private var offset = CGSize.zero
    @State private var accumulated = CGSize.zero
    @State private var showLiveCounts = false

    var body: some View {
        if state.isVisible {
            VStack(alignment: .leading, spacing: 4) {
                header
                metricRow(label: "MEM", value: String(format: "%.1f MB", sampler.latest.footprintMB), color: memColor)
                metricRow(label: "PEAK", value: String(format: "%.1f MB", Double(sampler.peakFootprintBytes) / 1_048_576), color: .secondary)
                metricRow(label: "CPU", value: String(format: "%.0f%%", sampler.latest.cpuPercent), color: cpuColor)
                metricRow(label: "THRDS", value: "\(sampler.latest.threadCount)", color: .secondary)
                if showLiveCounts {
                    Divider().background(Color.white.opacity(0.2))
                    Text(LeakTracker.liveCountSummary().isEmpty ? "no tracked instances" : LeakTracker.liveCountSummary())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: 200, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .offset(x: accumulated.width + offset.width, y: accumulated.height + offset.height)
            .gesture(
                DragGesture()
                    .onChanged { offset = $0.translation }
                    .onEnded { _ in accumulated.width += offset.width; accumulated.height += offset.height; offset = .zero }
            )
            .onTapGesture { showLiveCounts.toggle() }
            .padding(12)
            .transition(.opacity)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text("PERF").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Spacer(minLength: 12)
            Button { state.isVisible = false } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.6))
            }.buttonStyle(.plain)
        }
    }

    private func metricRow(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.5)).frame(width: 38, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
    }

    // Color thresholds — tune to the app's normal footprint once you've watched it run.
    private var memColor: Color {
        let mb = sampler.latest.footprintMB
        if mb > 1500 { return .red }
        if mb > 800 { return .orange }
        return .white
    }

    private var cpuColor: Color {
        let pct = sampler.latest.cpuPercent
        if pct > 90 { return .red }
        if pct > 50 { return .orange }
        return .white
    }
}
#endif

extension View {
    /// Overlays the perf HUD in the top-trailing corner. No-op in release.
    @ViewBuilder
    func perfOverlay() -> some View {
        #if DEBUG
        self.overlay(alignment: .topTrailing) { PerfOverlayView() }
        #else
        self
        #endif
    }
}
