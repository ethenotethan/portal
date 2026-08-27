import SwiftUI

// MARK: - CronInterflowGraphView

/// Cron interflow surface: a force-directed dataflow graph of every scheduled
/// job and the sources it reads, artifacts it writes, and sinks it drives.
/// Lives on the cron dashboard itself — a "Dataflow" panel on the macOS canvas
/// and a section in the iOS scroll — giving the dashboard's list/card views the
/// one thing they can't show: how jobs interflow through shared data. Rides the
/// same visual language as the wiki graph — glow nodes, curved typed edges,
/// drag/pan/zoom.
internal struct CronInterflowGraphView: View {
    @ObservedObject internal var viewModel: CronGraphViewModel
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper

    /// When set, the controls overlay shows an expand affordance that calls this
    /// — the host presents the full-screen dataflow takeover. Nil on the
    /// full-screen surface itself (there's nothing further to expand into).
    private let onExpand: (() -> Void)?
    /// The full-screen surface renders its own detail sidebar, so it suppresses
    /// the small in-graph detail card that the inline panel shows on selection.
    private let showsInlineDetailCard: Bool

    @MainActor
    internal init(
        viewModel: CronGraphViewModel? = nil,
        showsInlineDetailCard: Bool = true,
        onExpand: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel ?? CronGraphViewModel()
        self.showsInlineDetailCard = showsInlineDetailCard
        self.onExpand = onExpand
    }

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    private let healthTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    /// Whether the bottom-left legend is expanded. Persisted so the choice sticks
    /// across launches and stays in step between the inline panel and the
    /// full-screen surface. The legend stacks kinds, cron categories, and group
    /// toggles, so on a busy graph folding it away reclaims real estate.
    @AppStorage("cronGraphLegendExpanded") private var isLegendExpanded = true

    internal var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if viewModel.simNodes.isEmpty {
                emptyOrLoadingState
            } else {
                graphWithDock
            }

            if let error = viewModel.error, viewModel.simNodes.isEmpty {
                errorState(error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { _ in
            guard viewModel.simAlpha > 0.003 || viewModel.simNodes.contains(where: { $0.isDragging }) else { return }
            viewModel.tick()
        }
        .onReceive(healthTimer) { _ in
            guard viewModel.graph.nodes.contains(where: { $0.kind == "service" }) else { return }
            Task { await viewModel.refreshRuntimeState(client: gatewayClientWrapper.client) }
        }
        .onAppear {
            guard viewModel.graph.isEmpty else { return }
            Task { await viewModel.load(client: gatewayClientWrapper.client) }
        }
    }

    // MARK: - Graph + docked detail

    /// The graph fills the surface; selecting a node docks a definition panel on
    /// the trailing edge (the graph shrinks to make room), mirroring the wiki
    /// reader. This replaces the old tiny corner card — the complaint that
    /// clicking a cron "brought nothing up" was that card being too small to
    /// notice; a full-height dock reads unmistakably. Suppressed on the
    /// full-screen surface, which carries its own sidebar.
    @ViewBuilder
    private var graphWithDock: some View {
        HStack(spacing: 0) {
            if viewModel.showRevisions {
                CronRevisionTimelineDrawer(
                    viewModel: viewModel,
                    source: gatewayClientWrapper.client,
                    onClose: { viewModel.showRevisions = false }
                )
                .frame(width: 300)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(Theme.border)
            }
            ZStack {
                CronGraphCanvas(viewModel: viewModel)
                legendOverlay
                controlsOverlay
            }
            if showsInlineDetailCard, let node = viewModel.selectedNode {
                Divider().overlay(Theme.border)
                detailDock(node)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.selectedNodeIndex)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showRevisions)
    }

    // MARK: - States

    @ViewBuilder
    private var emptyOrLoadingState: some View {
        if viewModel.isLoading {
            ProgressView("Loading cron graph…")
                .tint(Theme.accent)
                .foregroundStyle(Theme.secondary)
        } else if viewModel.error == nil {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.secondary.opacity(0.5))
                Text("No cron dataflow yet")
                    .font(.headline)
                    .foregroundStyle(Theme.secondary)
                Text("Jobs that declare inputs, outputs, or side effects appear here.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Couldn't load the cron graph")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.load(client: gatewayClientWrapper.client) }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
        }
        .padding(24)
    }

    // MARK: - Overlays

    private var controlsOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                commitmentChip
                Spacer()
                controlButton(system: "clock.arrow.circlepath",
                              isActive: viewModel.showRevisions) {
                    viewModel.showRevisions.toggle()
                }
                .help(viewModel.showRevisions
                      ? "Hide the revision history"
                      : "Revision history — what changed in this dataflow, and when this app noticed")
                controlButton(system: "arrow.counterclockwise") {
                    Task { await viewModel.load(client: gatewayClientWrapper.client) }
                }
                .help("Reload the cron graph")
                controlButton(system: "minus.magnifyingglass") {
                    viewModel.zoomAtCenter(0.8)
                }
                .help("Zoom out")
                controlButton(system: "plus.magnifyingglass") {
                    viewModel.zoomAtCenter(1.25)
                }
                .help("Zoom in")
                controlButton(system: "scope") {
                    viewModel.resetView()
                }
                .help("Fit the whole graph to view")
                if let onExpand {
                    controlButton(system: "arrow.up.left.and.arrow.down.right") {
                        onExpand()
                    }
                    .help("Expand the dataflow to full screen")
                }
            }
            Spacer()
        }
        .padding(14)
    }

    /// The graph's commitment — a content address for the dataflow as
    /// configured. `cron.graph` returns only the present, so without this there
    /// is nothing to compare against what you saw yesterday and nothing to quote
    /// when reporting that the wiring changed. Clicking copies the full hash,
    /// which is the whole point of having one.
    ///
    /// Monospaced and prefixed like a short git hash because that is exactly what
    /// it is for, and a wiki changeset row already reads that way.
    private var commitmentChip: some View {
        Button {
            copy(viewModel.digest.hex)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "number")
                    .font(.system(size: 9, weight: .bold))
                // `.monospaced()` re-asserts against the app typeface's root
                // `.fontDesign`: a proportional hash reads as a word, not an address.
                Text(viewModel.digest.short)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospaced()
            }
            .foregroundStyle(Theme.secondary.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Theme.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Dataflow commitment \(viewModel.digest.short) — click to copy the full hash. "
              + viewModel.revisionLogSummary)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// `isActive` marks a button that toggles a surface rather than performing an
    /// action, so the drawer's control reads as pressed while the drawer is open.
    private func controlButton(
        system: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.secondary)
                .frame(width: 30, height: 30)
                .background(
                    isActive ? Theme.accent.opacity(0.14) : Theme.background.opacity(0.7),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? Theme.accent.opacity(0.5) : Theme.secondary.opacity(0.2),
                                lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
    }

    private var legendOverlay: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    legendHeader
                    if isLegendExpanded {
                        ForEach(CronGraphViewModel.legend, id: \.kind) { entry in
                            HStack(spacing: 7) {
                                CronNodeGlyphShape(glyph: viewModel.glyph(forKind: entry.kind))
                                    .fill(viewModel.color(forKind: entry.kind))
                                    .frame(width: 11, height: 11)
                                Text(entry.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        edgeLegendRows
                        categoryLegendRows
                        groupToggleRows
                    }
                }
                .padding(10)
                .background(Theme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Theme.secondary.opacity(0.15), lineWidth: 1)
                )
                Spacer()
            }
        }
        .padding(14)
    }

    /// The legend's toggle: the whole row is the hit target, so a single click
    /// folds the key away to just this chip or unfolds it again.
    private var legendHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isLegendExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 9, weight: .semibold))
                Text("Legend")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: isLegendExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.secondary.opacity(0.9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLegendExpanded ? "Hide the legend" : "Show the legend")
    }

    /// One row per edge type present, each a colored arrow, so the canvas
    /// arrowheads read back as reads / writes / feeds / delivers. Omitted before
    /// the graph has any edges.
    @ViewBuilder
    private var edgeLegendRows: some View {
        let edges = viewModel.edgeLegend
        if !edges.isEmpty {
            Divider()
                .overlay(Theme.secondary.opacity(0.2))
                .padding(.vertical, 1)
            Text("Edges")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
            ForEach(edges, id: \.type) { entry in
                HStack(spacing: 7) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(entry.color)
                        .frame(width: 11)
                    Text(entry.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    /// Under the kind legend, one swatch per cron category folder so a tinted
    /// cron node reads back to its folder. Omitted when no cron is categorized —
    /// there the base blue is the only cron color and needs no extra key.
    @ViewBuilder
    private var categoryLegendRows: some View {
        let categories = viewModel.categoryLegend
        if !categories.isEmpty {
            Divider()
                .overlay(Theme.secondary.opacity(0.2))
                .padding(.vertical, 1)
            Text("Categories")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
            ForEach(categories, id: \.name) { entry in
                HStack(spacing: 7) {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 9, height: 9)
                    Text(entry.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// One toggle per scheme group (≥2 members): fold the cluster into a single
    /// super-node or unfold it. The chevron shows the current state; the swatch
    /// carries the group's tint so the row, its hull, and its super-node read as
    /// one thing. Omitted when the graph has no multi-member scheme.
    @ViewBuilder
    private var groupToggleRows: some View {
        let groups = viewModel.groups
        if !groups.isEmpty {
            Divider()
                .overlay(Theme.secondary.opacity(0.2))
                .padding(.vertical, 1)
            Text("Groups")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
            ForEach(groups) { group in
                let collapsed = viewModel.isGroupCollapsed(group.key)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.toggleGroupCollapsed(group.key) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(viewModel.groupColor(forKey: group.key))
                        Text(group.key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Text("\(group.memberIDs.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary.opacity(0.6))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand the \(group.key) cluster" : "Collapse the \(group.key) cluster")
            }
        }
    }

    /// The docked definition panel: the selected node's identity and facts up
    /// top, its graph connections below (each row re-selects that neighbor so you
    /// can walk the dataflow without touching the canvas), and — inline only — an
    /// Expand button that hands off to the full-screen takeover for the node's
    /// full job card.
    private func detailDock(_ node: CronGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CronNodeGlyphShape(glyph: viewModel.glyph(forKind: node.kind))
                    .fill(viewModel.nodeColor(kind: node.kind, label: node.label))
                    .frame(width: 12, height: 12)
                Text(node.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                if let health = node.health {
                    CronServiceHealthBadge(health: health)
                }
                Spacer(minLength: 6)
                Button { viewModel.selectedNodeIndex = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(12)
            Divider().overlay(Theme.border.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(kindCaption(for: node))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                    if let schedule = node.schedule, !schedule.isEmpty {
                        detailRow(icon: "clock", value: schedule)
                    }
                    if node.kind == "cron" {
                        detailRow(icon: node.usesLLM ? "brain" : "terminal", value: node.usesLLM ? "LLM-driven" : "no-agent")
                        if !node.enabled {
                            detailRow(icon: "pause.circle", value: "paused")
                        }
                        if let status = node.lastStatus, !status.isEmpty {
                            detailRow(icon: "circle.fill", value: status)
                        }
                    }
                    // A service self-declares a markdown blurb of what it is / does;
                    // render it so expanding the node answers "wtf is this".
                    if node.kind == "service", !node.description.isEmpty {
                        Divider().overlay(Theme.border.opacity(0.4)).padding(.vertical, 2)
                        MarkdownContentView(text: node.description)
                    }
                    if let health = node.health {
                        CronServiceHealthDetails(health: health)
                    }
                    connectionsList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            if let onExpand {
                Divider().overlay(Theme.border.opacity(0.5))
                Button { onExpand() } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the full job detail")
            }
        }
        .background(Theme.surface.opacity(0.5))
    }


    /// The selected node's neighbors, each a button that re-selects it — the
    /// click-around navigation that lets the dock stand in for the graph.
    @ViewBuilder
    private var connectionsList: some View {
        let neighbors = viewModel.selectedNodeNeighbors()
            .filter { viewModel.simNodes.indices.contains($0) }
        if !neighbors.isEmpty {
            Divider().overlay(Theme.border.opacity(0.4)).padding(.vertical, 2)
            Text("Connections")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
            ForEach(neighbors, id: \.self) { idx in
                let neighbor = viewModel.simNodes[idx]
                Button { viewModel.selectNode(withID: neighbor.id) } label: {
                    HStack(spacing: 7) {
                        CronNodeGlyphShape(glyph: viewModel.glyph(forKind: neighbor.kind))
                            .fill(viewModel.nodeColor(kind: neighbor.kind, label: neighbor.label))
                            .frame(width: 9, height: 9)
                        Text(neighbor.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The small caption under a node's title: its kind for the actor nodes
    /// (cron / service), else the fine-grained ref scheme for a resource/sink.
    private func kindCaption(for node: CronGraphNode) -> String {
        switch node.kind {
        case "cron": return "cron job"
        case "service": return "service"
        default: return node.type
        }
    }

    private func detailRow(icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary.opacity(0.7))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}
