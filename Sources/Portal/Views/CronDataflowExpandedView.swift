import SwiftUI

// MARK: - CronDataflowExpandedView

/// The dataflow graph, taken full screen. The interflow graph fills the surface
/// (with its own pan/zoom) and a detail sidebar inspects the selected node:
///
/// - a **cron** node shows its full `CronJobCard` — the same expandable card the
///   dashboard's Jobs pane renders, with recent runs, dataflow, and actions;
/// - a **resource** node (source / artifact / sink) shows a compact card plus a
///   list of the nodes it connects to, each tappable to walk across the graph.
///
/// Tapping a dataflow chip inside the job card highlights the matching node and
/// swaps the sidebar to it — reads/writes become navigation. Escape (or the
/// collapse button) closes the takeover.
///
/// A **cron** node's sidebar also lists the code behind the job (its scripts
/// and declared source files, from the graph node itself); opening one adds a
/// read-only reader as a third column beside the sidebar — on a phone, a sheet
/// over the inspector — so the script a job runs is readable without leaving
/// the graph.
@MainActor
internal struct CronDataflowExpandedView: View {
    @ObservedObject internal var graphVM: CronGraphViewModel
    internal var listVM: CronListViewModel

    /// How to leave. nil means there is nowhere to go back to — the graph *is*
    /// the surface, as it is inside the **Graphs** section — so the collapse and
    /// Done affordances are dropped rather than left as dead controls.
    internal var onDismiss: (() -> Void)?

    /// Set when hosted by the **Graphs** section, which swaps the "Data flow"
    /// title for a dropdown onto its sibling wiki graph.
    internal var surfaceSelection: Binding<GraphSurface>?

    /// Cross-surface navigation supplied by `GraphsView`. Standalone dataflow
    /// surfaces omit it because they do not own the wiki surface to switch to.
    internal var onOpenWikiResource: ((CronGraphNode) -> Void)?

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @ObservedObject private var store = CronRunHistoryStore.shared
    /// Real per-run ledgers fetched on selection, keyed by job id — the same
    /// lazy load the Jobs pane does on card expand.
    @State private var ledgers: [String: [CronRunRecord]] = [:]
    /// The source-file explorer + reader state for the selected job.
    @StateObject private var sourceVM = CronSourceFilesViewModel()
    /// The service whose code knowledge graph is presented over the surface, if
    /// any — set from the resource card's button or a request handed up from the
    /// inline dock. Presented on its own code-topology surface.
    @State private var presentedCodeGraph: CodeGraphRequest?
    /// The service whose architecture model is presented over the surface, if
    /// any — from the resource card's button or a request from the inline dock.
    @State private var presentedArchitecture: ArchitectureRequest?

    internal init(
        graphVM: CronGraphViewModel,
        listVM: CronListViewModel,
        onDismiss: (() -> Void)?,
        surfaceSelection: Binding<GraphSurface>? = nil,
        onOpenWikiResource: ((CronGraphNode) -> Void)? = nil
    ) {
        self.graphVM = graphVM
        self.listVM = listVM
        self.onDismiss = onDismiss
        self.surfaceSelection = surfaceSelection
        self.onOpenWikiResource = onOpenWikiResource
    }

    internal var body: some View {
        expandedSurface
            .task { sourceVM.setClient(gatewayClientWrapper.client) }
            .task(id: graphVM.selectedNode?.id) { await loadSelected() }
            // A file asked for from the inline dock, before this surface existed:
            // open it once we're here, then clear the request so re-selecting the
            // node later doesn't replay it.
            .task(id: graphVM.requestedSourceFile) {
                guard let file = graphVM.requestedSourceFile else { return }
                graphVM.requestedSourceFile = nil
                await sourceVM.open(file)
            }
            // A code graph asked for from the inline dock, before this surface
            // existed: present it here, then clear the request so re-selecting
            // the service later doesn't replay it.
            .task(id: graphVM.requestedCodeGraph) {
                guard let request = graphVM.requestedCodeGraph else { return }
                graphVM.requestedCodeGraph = nil
                presentedCodeGraph = request
            }
            .task(id: graphVM.requestedArchitecture) {
                guard let request = graphVM.requestedArchitecture else { return }
                graphVM.requestedArchitecture = nil
                presentedArchitecture = request
            }
            // Selecting another node retires the reader: a file from job A open
            // beside job B's card would read as B's code.
            .onChange(of: graphVM.selectedNodeIndex) { _, _ in sourceVM.close() }
            .sheet(item: $presentedCodeGraph) { request in
                CodeGraphSurfaceView(request: request, client: gatewayClientWrapper.client)
            }
            .sheet(item: $presentedArchitecture) { request in
                ArchitectureSurfaceView(request: request, client: gatewayClientWrapper.client)
            }
    }

    private func openSourceFile(_ file: CronSourceFile) {
        Task { await sourceVM.open(file) }
    }

    @ViewBuilder
    private var expandedSurface: some View {
        #if os(iOS)
        if Self.layoutMode(isCompactWidth: horizontalSizeClass == .compact) == .compactSheet {
            compactSurface
        } else {
            regularSurface
        }
        #else
        regularSurface
            .overlay(alignment: .topLeading) { macTopLeadingChrome }
        #endif
    }

    /// iPhone keeps the graph at the full viewport width. Selecting a node opens
    /// its inspector as a native bottom sheet instead of squeezing a 360-point
    /// sidebar beside the canvas (which left effectively no graph on iPhone).
    #if os(iOS)
    private var compactSurface: some View {
        graphSurface
            .safeAreaInset(edge: .top, spacing: 0) { compactHeader }
            .sheet(isPresented: selectedNodeSheetBinding) {
                if let node = graphVM.selectedNode {
                    detailSidebar(node)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        // The reader stacks over the inspector sheet rather than
                        // beside it — there's no width for a third column here.
                        .sheet(isPresented: readerSheetBinding) {
                            CronSourceFileReaderPane(viewModel: sourceVM, onClose: { sourceVM.close() })
                                .presentationDetents([.large])
                                .presentationDragIndicator(.visible)
                        }
                }
            }
    }

    private var readerSheetBinding: Binding<Bool> {
        Binding(
            get: { sourceVM.isPresentingReader },
            set: { isPresented in
                if !isPresented { sourceVM.close() }
            }
        )
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let surfaceSelection {
                    GraphSurfaceMenu(selection: surfaceSelection)
                } else {
                    Text("Data flow")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                }
                Text("Tap a node to inspect it")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let onDismiss {
                Button("Done", action: onDismiss)
                    .font(.body.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("cron.dataflow.done")
            }
        }
        .padding(.horizontal, 16)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    private var selectedNodeSheetBinding: Binding<Bool> {
        Binding(
            get: { graphVM.selectedNode != nil },
            set: { isPresented in
                if !isPresented { graphVM.selectedNodeIndex = nil }
            }
        )
    }
    #endif

    private var regularSurface: some View {
        HStack(spacing: 0) {
            graphSurface

            if let node = graphVM.selectedNode {
                Divider().overlay(Theme.border)
                detailSidebar(node)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                if sourceVM.isPresentingReader {
                    Divider().overlay(Theme.border)
                    CronSourceFileReaderPane(viewModel: sourceVM, onClose: { sourceVM.close() })
                        .frame(minWidth: 380, idealWidth: 540, maxWidth: 680)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: graphVM.selectedNodeIndex)
        .animation(.easeInOut(duration: 0.18), value: sourceVM.isPresentingReader)
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) { compactHeader }
        #endif
    }

    private var graphSurface: some View {
        CronInterflowGraphView(viewModel: graphVM, showsInlineDetailCard: false)
            .environmentObject(gatewayClientWrapper)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
    }

    internal enum LayoutMode: Equatable {
        case compactSheet
        case regularSidebar
    }

    internal static func layoutMode(isCompactWidth: Bool) -> LayoutMode {
        isCompactWidth ? .compactSheet : .regularSidebar
    }

    // MARK: - Chrome

    /// The macOS canvas has no header bar, so its title and its way out both
    /// float over the top-leading corner. Either can be absent: inside the
    /// **Graphs** section there is nothing to collapse back to, and as a
    /// standalone takeover there is no sibling graph to name.
    @ViewBuilder
    private var macTopLeadingChrome: some View {
        HStack(spacing: 8) {
            if let onDismiss {
                collapseButton(onDismiss)
            }
            if let surfaceSelection {
                GraphSurfaceMenu(selection: surfaceSelection)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(14)
    }

    private func collapseButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Close full screen")
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func detailSidebar(_ node: CronGraphNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if node.kind == "cron", let job = listVM.jobs.first(where: { $0.id == node.id }) {
                    cronCard(job)
                } else {
                    resourceCard(node)
                }
                // The code behind the node — a cron's scripts, a service's declared
                // files — from the node itself, whether or not the job list has
                // caught up with it.
                if !node.sourceFiles.isEmpty {
                    CronSourceFilesSection(
                        files: node.sourceFiles,
                        viewModel: sourceVM,
                        onOpen: openSourceFile
                    )
                }
            }
            .padding(12)
        }
        .background(Theme.surface.opacity(0.4))
    }

    private func cronCard(_ job: CronJob) -> some View {
        CronJobCard(
            job: job,
            isExpanded: true,
            runRecords: records(for: job.id),
            onToggle: {},
            onPause: { Task { await listVM.pauseJob(id: job.id) } },
            onResume: { Task { await listVM.resumeJob(id: job.id) } },
            onRemove: { Task { await listVM.removeJob(id: job.id) } },
            onUpdatePrompt: { prompt in Task { await listVM.updatePrompt(id: job.id, newPrompt: prompt) } },
            onRename: { name in Task { await listVM.renameJob(id: job.id, newName: name) } },
            siblingJobs: listVM.jobs,
            showsCategoryPath: true,
            dataflow: listVM.dataflow(for: job.id),
            onSelectEndpoint: { graphVM.selectNode(withID: $0.id) }
        )
    }

    private func resourceCard(_ node: CronGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(graphVM.nodeColor(kind: node.kind, label: node.label))
                    .frame(width: 10, height: 10)
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                if let health = node.health {
                    Text(health.status.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            health.isHealthy ? Color.green : (health.isUnhealthy ? Color.red : Color.orange)
                        )
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            (health.isHealthy ? Color.green : (health.isUnhealthy ? Color.red : Color.orange)).opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            infoRow(icon: "square.stack.3d.up", label: "Kind", value: node.kind)
            if !node.type.isEmpty, node.type != node.kind {
                infoRow(icon: "tag", label: "Type", value: node.type)
            }
            if node.kind == "service", !node.description.isEmpty {
                MarkdownContentView(text: node.description)
            }
            if node.kind == "service", let codeGraph = node.codeGraph {
                Button {
                    presentedCodeGraph = CodeGraphRequest(
                        service: codeGraph.ref,
                        label: node.label,
                        digest: codeGraph.digest
                    )
                } label: {
                    Label("View code graph", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            if node.wikiPagePath != nil, let onOpenWikiResource {
                Button {
                    onOpenWikiResource(node)
                } label: {
                    Label("Open wiki page", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("runtime.graph.open-wiki-page")
            }
            if node.kind == "service", let architecture = node.architecture {
                Button {
                    presentedArchitecture = ArchitectureRequest(
                        service: architecture.ref,
                        label: node.label,
                        revision: architecture.revision
                    )
                } label: {
                    Label("View architecture", systemImage: "square.3.layers.3d")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                infoRow(icon: "square.3.layers.3d", label: "Model", value: "\(architecture.source) · \(architecture.revision.prefix(9))")
                if architecture.snapshots > 0 {
                    infoRow(icon: "clock.arrow.circlepath", label: "Snapshots", value: String(architecture.snapshots))
                }
                if let status = architecture.checkStatus {
                    infoRow(icon: "checkmark.seal", label: "Last check", value: status)
                }
            }
            if let health = node.health {
                Divider().background(Theme.border)
                Text("Health")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                infoRow(icon: "stethoscope", label: "Probe", value: health.probe)
                if !health.target.isEmpty {
                    infoRow(icon: "scope", label: "Target", value: health.target)
                }
                infoRow(icon: "waveform.path.ecg", label: "Result", value: health.message)
                if health.latencyMilliseconds > 0 {
                    infoRow(
                        icon: "timer",
                        label: "Latency",
                        value: String(format: "%.1f ms", health.latencyMilliseconds)
                    )
                }
                if !health.checkedAt.isEmpty {
                    infoRow(icon: "clock.arrow.circlepath", label: "Checked", value: health.checkedAt)
                }
            }
            neighborsList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Spacer()
        }
    }

    /// The selected resource's neighbors — the jobs that read/write it and any
    /// resources it chains to — each a tap-target that re-selects across the
    /// graph, so a resource card is a hop rather than a dead end.
    @ViewBuilder
    private var neighborsList: some View {
        let neighbors = graphVM.selectedNodeNeighbors()
        if !neighbors.isEmpty {
            Divider().background(Theme.border)
            Text("Connected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
            ForEach(neighbors, id: \.self) { index in
                if graphVM.simNodes.indices.contains(index) {
                    neighborRow(graphVM.simNodes[index])
                }
            }
        }
    }

    private func neighborRow(_ node: CronGraphViewModel.SimNode) -> some View {
        Button {
            graphVM.selectNode(withID: node.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(graphVM.nodeColor(kind: node.kind, label: node.label))
                    .frame(width: 7, height: 7)
                Text(node.label)
                    .font(.caption)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    /// Prefer the fetched ledger (real durations); fall back to the passively
    /// observed store so the card is never empty before history returns.
    private func records(for jobID: String) -> [CronRunRecord] {
        if let ledger = ledgers[jobID], !ledger.isEmpty {
            return ledger.sorted { $0.firedAt < $1.firedAt }
        }
        return store.records(for: jobID)
    }

    private func loadSelected() async {
        guard let node = graphVM.selectedNode, node.kind == "cron" else { return }
        await listVM.loadFullPrompt(id: node.id)
        let runs = await listVM.loadHistory(id: node.id)
        if !runs.isEmpty { ledgers[node.id] = runs }
    }
}

/// Purpose-built code topology surface. It deliberately uses only the shared
/// force-directed canvas, not `WikiGraphView`: users see code nodes/edges and
/// code-specific loading/empty/error states rather than a nested "Wiki" app.
@MainActor
internal struct CodeGraphSurfaceView: View {
    private let request: CodeGraphRequest
    @StateObject private var model: CodeGraphSurfaceModel
    @Environment(\.dismiss) private var dismiss

    internal init(request: CodeGraphRequest, client: GatewayClient) {
        self.request = request
        _model = StateObject(
            wrappedValue: CodeGraphSurfaceModel {
                try await client.codeGraph(service: request.service)
            }
        )
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            content
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
        .background(Theme.background)
        .task(id: request.digest) { await model.load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.label)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .portalButton(prominent: true, size: .small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var summary: String {
        guard let graph = model.codeGraph else { return "Code graph" }
        return "\(graph.nodes.count) nodes · \(graph.edges.count) edges"
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            stateMessage(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Building code graph",
                detail: "Extracting modules, symbols, and relationships…",
                showsProgress: true
            )
        case .loaded:
            InteractiveGraphView(graph: model.renderGraph)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            stateMessage(
                icon: "curlybraces",
                title: "No code symbols found",
                detail: "The service has no graphable source files in an allowed source root."
            )
        case .failed:
            VStack(spacing: 14) {
                stateMessage(
                    icon: "exclamationmark.triangle",
                    title: "Code graph unavailable",
                    detail: model.errorMessage ?? "The gateway could not build this service's code graph."
                )
                Button("Try Again") { Task { await model.load() } }
                    .portalButton(prominent: false, size: .small)
            }
        }
    }

    private func stateMessage(
        icon: String,
        title: String,
        detail: String,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
