import SwiftUI

/// THE wiki toolbar: the single container for every control that floats over
/// the adaptive graph surface (top-trailing). New affordances (e.g. a
/// source-specific timeline) belong here — add a button to this bar rather
/// than scattering conditionals through WikiGraphView.
internal struct WikiGraphControlsBar: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel
    /// Changeset timeline is a per-source capability (WikiChangesetSource);
    /// the host computes conformance and the bar just hides the toggle.
    internal let supportsTimeline: Bool
    /// Whether an ingestion event log exists (WikiEventLogSource) — gates the
    /// Events door. A Bool rather than the source itself: the host resolves the
    /// capability against the *effective* source, which for the home gateway is
    /// the shared client and not any injected override. Handing this bar an
    /// override that is nil in the normal case is what previously left the
    /// Events entry unrenderable on Hermes.
    internal let hasEventsSurface: Bool
    internal let onRefresh: () -> Void

    internal var body: some View {
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

        historyControl
    }

    // MARK: - History (one door)

    /// Whether any history surface is active right now (drives the icon tint).
    private var historyActive: Bool {
        (supportsTimeline && viewModel.showTimeline) ||
        (hasEventsSurface && viewModel.showEventsPage)
    }

    /// Change history was reached through two separate, similarly clock-ish
    /// toolbar icons — the edit-timeline drawer AND the event feed — which read
    /// as "wait, which one is the history?". Fold them into a single door: when
    /// both surfaces exist it's a menu (Changes / Events); when only one does it
    /// stays a direct toggle so there's no extra click.
    ///
    /// Both now exist on both backends, so the menu is the usual shape. The
    /// single-surface branches remain live for a source that conforms to one
    /// capability and not the other — the whole point of gating on capabilities
    /// rather than on which backend is connected.
    @ViewBuilder
    private var historyControl: some View {
        if supportsTimeline && hasEventsSurface {
            Menu {
                Button { toggleTimeline() } label: {
                    historyMenuLabel("Changes", systemImage: "clock.arrow.circlepath", on: viewModel.showTimeline)
                }
                Button { toggleEventsPage() } label: {
                    historyMenuLabel("Events", systemImage: "tray.and.arrow.down", on: viewModel.showEventsPage)
                }
            } label: {
                historyIcon
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Wiki history — page changes and ingested events")
        } else if supportsTimeline {
            Button { toggleTimeline() } label: { historyIcon }
                .buttonStyle(.borderless)
                .help(viewModel.showTimeline ? "Hide change history" : "Change history — what edited each page")
        } else if hasEventsSurface {
            Button { toggleEventsPage() } label: { historyIcon }
                .buttonStyle(.borderless)
                .help(viewModel.showEventsPage ? "Back to the wiki graph" : "Event history — what flowed into the wiki")
        }
    }

    private var historyIcon: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(historyActive ? Theme.accent : Theme.secondary)
    }

    @ViewBuilder
    private func historyMenuLabel(_ title: String, systemImage: String, on: Bool) -> some View {
        if on {
            Label(title, systemImage: "checkmark")
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private func toggleTimeline() {
        withAnimation(.easeInOut(duration: 0.2)) {
            // Opening the drawer and the full events page at once would fight
            // over the surface; leaving events closes it as we open the drawer.
            if !viewModel.showTimeline { viewModel.showEventsPage = false }
            viewModel.showTimeline.toggle()
        }
    }

    private func toggleEventsPage() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if !viewModel.showEventsPage { viewModel.showTimeline = false }
            viewModel.showEventsPage.toggle()
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
