import SwiftUI

/// THE wiki toolbar: the single container for every control that floats over
/// the adaptive graph surface (top-trailing). New affordances (e.g. a
/// source-specific timeline) belong here — add a button to this bar rather
/// than scattering conditionals through WikiGraphView.
struct WikiGraphControlsBar: View {
    @ObservedObject var viewModel: WikiGraphViewModel
    /// Changeset timeline is a per-source capability (WikiChangesetSource);
    /// the host computes conformance and the bar just hides the toggle.
    let supportsTimeline: Bool
    /// The wiki source being browsed — the event-timeline button gates
    /// itself on WikiEventTimelineProviding conformance (Centaur only).
    let source: (any WikiSource)?
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if !viewModel.is3D {
                zoomCluster
                Divider().frame(height: 14)
            }

            surfaceToggles

            Divider().frame(height: 14)

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Reload wiki")
        }
        .foregroundStyle(Theme.secondary)
        .padding(12)
    }

    // MARK: - Zoom (2D canvas only; SceneKit owns the 3D camera)

    private var zoomCluster: some View {
        HStack(spacing: 6) {
            Button {
                zoomAtCenter(factor: 0.8)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Text("\(Int(viewModel.zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 32)

            Button {
                zoomAtCenter(factor: 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    viewModel.resetView()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Reset view")
        }
    }

    private func zoomAtCenter(factor: CGFloat) {
        let c = CGPoint(x: viewModel.canvasSize.width / 2, y: viewModel.canvasSize.height / 2)
        withAnimation(.easeOut(duration: 0.22)) {
            viewModel.zoomAtPoint(factor: factor, around: c)
        }
    }

    // MARK: - Surface toggles (3D rendering, file tree, timeline drawer)

    @ViewBuilder
    private var surfaceToggles: some View {
        Button {
            viewModel.setRendering3D(!viewModel.is3D)
        } label: {
            Image(systemName: "cube.transparent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.is3D ? Theme.accent : Theme.secondary)
        }
        .buttonStyle(.borderless)
        .help(viewModel.is3D ? "Switch to 2D graph" : "Switch to 3D graph")

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showFileTree.toggle()
            }
        } label: {
            Image(systemName: sidebarIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.showFileTree ? Theme.accent : Theme.secondary)
        }
        .buttonStyle(.borderless)
        .help(viewModel.showFileTree ? "Hide page browser" : "Browse pages")

        if supportsTimeline {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showTimeline.toggle()
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.showTimeline ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.showTimeline ? "Hide timeline" : "Show change timeline")
        }

        // Events page toggle: navigates the wiki surface to the full
        // Compendium events page (graph ↔ events swap in the adaptive
        // host), not an overlay. Centaur-only by protocol conformance.
        if source is (any WikiEventTimelineProviding) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showEventsPage.toggle()
                }
            } label: {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.showEventsPage ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.borderless)
            .help(viewModel.showEventsPage ? "Back to the wiki graph" : "Events — Compendium ingestion timeline")
        }
    }

    private var sidebarIcon: String {
        #if os(macOS)
        return "sidebar.left"
        #else
        return "list.bullet"
        #endif
    }
}
