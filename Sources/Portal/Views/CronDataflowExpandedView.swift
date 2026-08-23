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
@MainActor
internal struct CronDataflowExpandedView: View {
    @ObservedObject internal var graphVM: CronGraphViewModel
    internal var listVM: CronListViewModel
    internal var onDismiss: () -> Void

    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @ObservedObject private var store = CronRunHistoryStore.shared
    /// Real per-run ledgers fetched on selection, keyed by job id — the same
    /// lazy load the Jobs pane does on card expand.
    @State private var ledgers: [String: [CronRunRecord]] = [:]

    internal init(
        graphVM: CronGraphViewModel,
        listVM: CronListViewModel,
        onDismiss: @escaping () -> Void
    ) {
        self.graphVM = graphVM
        self.listVM = listVM
        self.onDismiss = onDismiss
    }

    internal var body: some View {
        expandedSurface
            .task(id: graphVM.selectedNode?.id) { await loadSelected() }
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
            .overlay(alignment: .topLeading) { collapseButton }
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
                }
            }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Data flow")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text("Tap a node to inspect it")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Done", action: onDismiss)
                .font(.body.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("cron.dataflow.done")
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
            }
        }
        .animation(.easeInOut(duration: 0.18), value: graphVM.selectedNodeIndex)
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

    private var collapseButton: some View {
        Button(action: onDismiss) {
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
        .padding(14)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func detailSidebar(_ node: CronGraphNode) -> some View {
        ScrollView {
            Group {
                if node.kind == "cron", let job = listVM.jobs.first(where: { $0.id == node.id }) {
                    cronCard(job)
                } else {
                    resourceCard(node)
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
            supportsRemoveAndEdit: listVM.supportsRemoveAndEdit,
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
