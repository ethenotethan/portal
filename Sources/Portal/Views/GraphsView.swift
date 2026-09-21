import SwiftUI

// MARK: - GraphSurfaceTitle

/// What the switcher *reads* as: the selected graph's name, with a chevron for
/// the sibling behind it.
///
/// Factored out of `GraphSurfaceMenu` so the thing a reader actually sees can be
/// rendered on its own. A `Menu` needs AppKit's menu hosting, so it draws as an
/// unavailable-content placeholder under a headless `ImageRenderer` — a snapshot
/// golden of the whole control would pin a blank box and never catch a title
/// wired to the wrong side of the binding. This view has no such dependency, so
/// the gate sees the text.
internal struct GraphSurfaceTitle: View {
    internal let surface: GraphSurface

    internal var body: some View {
        HStack(spacing: 4) {
            Text(surface.label)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - GraphSurfaceMenu

/// The dropdown that replaced the bare "Wiki" title.
///
/// It renders as a *title* rather than as a control on purpose: it sits exactly
/// where each graph's own headline used to sit, so the section still reads
/// "here is the wiki graph" at a glance, and the chevron is the only hint that
/// there is a sibling graph behind it. Both graphs host this same view, which is
/// what makes switching feel like one section with two views instead of two
/// destinations that happen to be adjacent.
internal struct GraphSurfaceMenu: View {
    @Binding internal var selection: GraphSurface

    internal var body: some View {
        Menu {
            ForEach(GraphSurface.allCases) { surface in
                Button {
                    selection = surface
                } label: {
                    Label(surface.label, systemImage: surface.systemImage)
                }
            }
        } label: {
            GraphSurfaceTitle(surface: selection)
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selection.summary)
        .accessibilityIdentifier("graphs.surface.picker")
        .accessibilityLabel("Graph shown")
        .accessibilityValue(selection.label)
    }
}

// MARK: - GraphsView

/// The **Graphs** section: one door onto both of Portal's graphs.
///
/// The wiki knowledge graph and the cron dataflow graph describe the same
/// harness from two angles — what it knows, and what it does — so they now share
/// a section and a switcher instead of living a top-level door and a buried
/// dashboard pane apart. `GraphSurfaceMenu` is injected into whichever graph is
/// showing, replacing that graph's own title.
///
/// The cron view models are owned here (not by the caller) because the runtime
/// graph has no other home now; they stay alive across a switch to the wiki and
/// back, so returning to the runtime graph doesn't re-fetch or lose the selected
/// node.
@MainActor
internal struct GraphsView: View {
    @ObservedObject internal var wikiViewModel: WikiGraphViewModel

    /// Knowledge-base source override for the wiki graph — e.g. CodeGraphSource
    /// passes a service's code graph. The runtime graph is harness-only, so an
    /// override also means the switcher has nothing to switch to.
    internal var overrideSource: (any WikiSource)?

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    /// Persisted so the section reopens on the graph you left it on.
    @AppStorage("graphs.surface") private var storedSurface = GraphSurface.wiki.rawValue

    @StateObject private var cronGraphVM = CronGraphViewModel()
    @State private var cronListVM = CronListViewModel()
    @ObservedObject private var runHistory = CronRunHistoryStore.shared

    @MainActor
    internal init(wikiViewModel: WikiGraphViewModel, overrideSource: (any WikiSource)? = nil) {
        self.wikiViewModel = wikiViewModel
        self.overrideSource = overrideSource
    }

    /// A code-graph override has no cron dataflow behind it, so the section
    /// collapses back to the plain wiki graph rather than offering a switch that
    /// would land on an empty canvas.
    private var offersSwitcher: Bool { overrideSource == nil }

    private var surface: GraphSurface {
        offersSwitcher ? GraphSurface.stored(storedSurface) : .wiki
    }

    private var surfaceBinding: Binding<GraphSurface>? {
        guard offersSwitcher else { return nil }
        return Binding(
            get: { GraphSurface.stored(storedSurface) },
            set: { storedSurface = $0.rawValue }
        )
    }

    internal var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            // Job rows feed the runtime graph's node inspector (cards, run
            // history, source files). Seed them when that graph is first shown
            // rather than on section open, so a wiki-only visit costs no RPCs.
            .task(id: surface) {
                guard surface == .runtime else { return }
                await seedJobsIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .wiki:
            WikiGraphView(
                viewModel: wikiViewModel,
                overrideSource: overrideSource,
                surfaceSelection: surfaceBinding
            )
            .environmentObject(gatewayClientWrapper)
        case .runtime:
            CronDataflowExpandedView(
                graphVM: cronGraphVM,
                listVM: cronListVM,
                onDismiss: nil,
                surfaceSelection: surfaceBinding
            )
            .environmentObject(gatewayClientWrapper)
        }
    }

    /// Mirrors what the Cron Activity surface used to do before it handed the
    /// graph over: load jobs, then let the history store seed and diff them.
    private func seedJobsIfNeeded() async {
        guard cronListVM.jobs.isEmpty else { return }
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        runHistory.seedFromJobs(cronListVM.jobs)
        runHistory.detectNewRuns(from: cronListVM.jobs)
    }
}
