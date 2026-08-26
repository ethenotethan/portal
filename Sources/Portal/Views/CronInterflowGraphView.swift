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
        .help("Dataflow commitment \(viewModel.digest.short) — click to copy the full hash")
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func controlButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.secondary.opacity(0.2), lineWidth: 1)
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

// MARK: - CronGraphCanvas

/// The force-directed 2D canvas for the cron graph. Curved typed edges, glow
/// nodes, screen-space labels, and the platform input layer (NSView mouse
/// interception on macOS via the shared `GraphMouseInterceptor`, DragGesture on
/// iOS) — the same interaction model as `WikiGraph2DCanvas`.
private struct CronGraphCanvas: View {
    @ObservedObject fileprivate var viewModel: CronGraphViewModel

    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragNodeIndex: Int?
    /// The zoom at the start of the current pinch — `MagnificationGesture`'s
    /// value is relative (starts at 1.0), so we scale from this baseline, which
    /// is re-seeded from the live zoom at each gesture start so a pinch never
    /// jumps after a button/fit zoom in between.
    @State private var lastPinchScale: CGFloat = 1.0
    @State private var isPinching = false

    private enum MouseState {
        case idle, deciding, panning, draggingNode
    }

    fileprivate var body: some View {
        ZStack {
            canvas

            #if os(macOS)
            GraphMouseInterceptor(
                onMouseDown: { pt in handleMouseDown(pt) },
                onMouseDragged: { pt in handleMouseDragged(pt) },
                onMouseUp: { pt in handleMouseUp(pt) },
                onScrollWheel: { delta in handleScrollWheel(delta) },
                onMouseMoved: { pt in
                    if mouseState == .idle { viewModel.updateHover(at: pt) }
                },
                onMouseExited: { viewModel.clearHover() }
            )
            #else
            Color.clear
                .contentShape(Rectangle())
                .gesture(iosDragGesture)
            #endif
        }
        .gesture(pinchGesture)
    }

    /// Trackpad pinch (and iOS pinch) → zoom about the canvas center, homing on
    /// the middle of the view. Mirrors the wiki graph's `pinchGesture`.
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if !isPinching { isPinching = true; lastPinchScale = viewModel.zoom }
                let targetZoom = lastPinchScale * value
                let clamped = max(0.3, min(5.0, targetZoom))
                let oldZoom = viewModel.zoom
                guard abs(clamped - oldZoom) > 0.001 else { return }
                let center = CGPoint(x: viewModel.canvasSize.width / 2,
                                     y: viewModel.canvasSize.height / 2)
                viewModel.zoomAtPoint(factor: clamped / oldZoom, around: center)
            }
            .onEnded { _ in
                isPinching = false
            }
    }

    // MARK: - Mouse handlers

    private func handleMouseDown(_ pt: CGPoint) {
        mouseState = .deciding
        dragStartPan = viewModel.panOffset
        dragStartPoint = pt
        dragNodeIndex = viewModel.hitTest(point: pt)
    }

    private func handleMouseDragged(_ pt: CGPoint) {
        let dx = pt.x - dragStartPoint.x
        let dy = pt.y - dragStartPoint.y
        let dist = hypot(dx, dy)
        switch mouseState {
        case .deciding:
            if dist > 5 {
                if let idx = dragNodeIndex {
                    mouseState = .draggingNode
                    viewModel.startDragging(index: idx, at: pt)
                } else {
                    mouseState = .panning
                }
            }
        case .panning:
            viewModel.panOffset = CGSize(width: dragStartPan.width + dx, height: dragStartPan.height + dy)
        case .draggingNode:
            if let idx = dragNodeIndex { viewModel.dragNode(index: idx, to: pt) }
        case .idle:
            break
        }
    }

    private func handleMouseUp(_ pt: CGPoint) {
        if mouseState == .deciding { viewModel.handleTap(at: dragStartPoint) }
        if let idx = dragNodeIndex { viewModel.stopDragging(index: idx) }
        mouseState = .idle
        dragNodeIndex = nil
    }

    private func handleScrollWheel(_ delta: CGSize) {
        viewModel.panOffset = CGSize(
            width: viewModel.panOffset.width + delta.width,
            height: viewModel.panOffset.height + delta.height
        )
    }

    #if !os(macOS)
    private var iosDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                switch mouseState {
                case .idle:
                    mouseState = .deciding
                    dragStartPan = viewModel.panOffset
                    dragStartPoint = value.startLocation
                    dragNodeIndex = viewModel.hitTest(point: value.startLocation)
                case .deciding:
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist > 5 {
                        if let idx = dragNodeIndex {
                            mouseState = .draggingNode
                            viewModel.startDragging(index: idx, at: value.location)
                        } else {
                            mouseState = .panning
                        }
                    }
                case .panning:
                    viewModel.panOffset = CGSize(
                        width: dragStartPan.width + value.translation.width,
                        height: dragStartPan.height + value.translation.height
                    )
                case .draggingNode:
                    if let idx = dragNodeIndex { viewModel.dragNode(index: idx, to: value.location) }
                }
            }
            .onEnded { value in
                if mouseState == .deciding { viewModel.handleTap(at: value.startLocation) }
                if let idx = dragNodeIndex { viewModel.stopDragging(index: idx) }
                mouseState = .idle
                dragNodeIndex = nil
            }
    }
    #endif

    // MARK: - Drawing

    private var canvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let hasSelection = viewModel.highlightAnchor != nil
                let zoom = viewModel.zoom
                let pan = viewModel.panOffset

                context.translateBy(x: pan.width, y: pan.height)
                context.scaleBy(x: zoom, y: zoom)

                drawHulls(context: context, hasSelection: hasSelection)
                drawEdges(context: context, hasSelection: hasSelection)
                drawNodes(context: context, hasSelection: hasSelection)

                guard mouseState != .panning && mouseState != .draggingNode else { return }
                context.transform = .identity
                drawHullLabels(context: &context, size: size)
                drawLabels(context: &context, size: size, hasSelection: hasSelection)
            }
            .onAppear {
                let wasZero = viewModel.canvasSize == .zero
                viewModel.canvasSize = geo.size
                if geo.size != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.isEmpty {
                    viewModel.setupSimulation()
                } else if wasZero && geo.size != .zero {
                    // Nodes were settled against the nominal size before the
                    // canvas had real bounds — reframe once for the real size.
                    viewModel.fitToView()
                }
            }
            .onChange(of: geo.size) { _, newSize in
                let wasZero = viewModel.canvasSize == .zero
                viewModel.canvasSize = newSize
                if newSize != .zero && viewModel.simNodes.isEmpty && !viewModel.graph.isEmpty {
                    viewModel.setupSimulation()
                } else if wasZero && newSize != .zero {
                    viewModel.fitToView()
                }
            }
        }
    }

    /// Soft scheme boundaries behind the graph — the "circle around the inner
    /// circles". Only expanded groups draw a hull; a collapsed one is already a
    /// single super-node. Dimmed along with its members when a selection is
    /// active elsewhere, so the highlighted subgraph stays the focus.
    private func drawHulls(context: GraphicsContext, hasSelection: Bool) {
        let byID = Dictionary(viewModel.simNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Expanded scheme clusters (a collapsed one is already a single super-node).
        for group in viewModel.groups where !viewModel.isGroupCollapsed(group.key) {
            drawHull(context: context, byID: byID, hasSelection: hasSelection,
                     memberIDs: group.memberIDs, tint: viewModel.groupColor(forKey: group.key))
        }
        // Cron category folders — a visual grouping only, drawn the same way.
        for hull in viewModel.categoryHulls {
            drawHull(context: context, byID: byID, hasSelection: hasSelection,
                     memberIDs: hull.memberIDs, tint: hull.color)
        }
    }

    /// Draw one soft boundary around a member set. The cohesion force keeps the
    /// members tight, so the convex-hull-plus-padding stays compact rather than
    /// sweeping unrelated nodes inside.
    private func drawHull(context: GraphicsContext, byID: [String: CronGraphViewModel.SimNode],
                          hasSelection: Bool, memberIDs: [String], tint: Color) {
        let members = memberIDs.compactMap { byID[$0] }
        guard members.count >= 2 else { return }
        let points = members.map(\.position)
        let padding = (members.map { viewModel.radius(forKind: $0.kind) }.max() ?? 8) + 20
        let path = CronGroupHull.path(around: points, padding: padding)
        let anyConnected = !hasSelection || members.contains { member in
            viewModel.simNodes.firstIndex { $0.id == member.id }.map { viewModel.isNodeConnectedToSelection($0) } ?? false
        }
        let dim: CGFloat = anyConnected ? 1 : 0.3
        context.fill(path, with: .color(tint.opacity(0.08 * dim)))
        context.stroke(path, with: .color(tint.opacity(0.4 * dim)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
    }

    /// Group names above each hull, drawn in screen space so the label stays a
    /// constant size regardless of zoom — same reasoning as the node labels.
    private func drawHullLabels(context: inout GraphicsContext, size: CGSize) {
        let byID = Dictionary(viewModel.simNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for group in viewModel.groups where !viewModel.isGroupCollapsed(group.key) {
            drawHullLabel(context: &context, size: size, byID: byID, memberIDs: group.memberIDs,
                          title: group.key, tint: viewModel.groupColor(forKey: group.key))
        }
        for hull in viewModel.categoryHulls {
            drawHullLabel(context: &context, size: size, byID: byID, memberIDs: hull.memberIDs,
                          title: hull.key, tint: hull.color)
        }
    }

    private func drawHullLabel(context: inout GraphicsContext, size: CGSize,
                               byID: [String: CronGraphViewModel.SimNode],
                               memberIDs: [String], title: String, tint: Color) {
        let members = memberIDs.compactMap { byID[$0] }
        guard members.count >= 2 else { return }
        let minX = members.map { $0.position.x }.min() ?? 0
        let maxX = members.map { $0.position.x }.max() ?? 0
        let minY = members.map { $0.position.y }.min() ?? 0
        let anchorGraph = CGPoint(x: (minX + maxX) / 2, y: minY)
        let screen = CGPoint(
            x: anchorGraph.x * viewModel.zoom + viewModel.panOffset.width,
            y: anchorGraph.y * viewModel.zoom + viewModel.panOffset.height - 22
        )
        guard screen.x > -80, screen.x < size.width + 80, screen.y > -20, screen.y < size.height + 20 else { return }
        context.draw(
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(tint.opacity(0.9)),
            at: screen, anchor: .center
        )
    }

    private func drawEdges(context: GraphicsContext, hasSelection: Bool) {
        for (linkIndex, (si, ti)) in viewModel.simLinks.enumerated() {
            guard viewModel.simNodes.indices.contains(si),
                  viewModel.simNodes.indices.contains(ti) else { continue }
            let sp = viewModel.simNodes[si].position
            let tp = viewModel.simNodes[ti].position
            let isConnected = !hasSelection || viewModel.linkIsConnectedToSelection(si, ti)

            let mid = CGPoint(x: (sp.x + tp.x) / 2, y: (sp.y + tp.y) / 2)
            let dx = tp.x - sp.x, dy = tp.y - sp.y
            let len = max(hypot(dx, dy), 1)
            let bow = min(len * 0.12, 26)
            let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)

            let type = linkIndex < viewModel.simLinkTypes.count ? viewModel.simLinkTypes[linkIndex] : "reads"
            let baseColor = viewModel.edgeColor(forType: type)
            let isContainment = viewModel.edgeIsContainment(type)

            var path = Path()
            path.move(to: sp)
            path.addQuadCurve(to: tp, control: ctrl)
            if isContainment {
                // Dashed: a `hosts` edge is containment, not flow. Nothing
                // travels along it, so it must not look like the solid dataflow
                // arrows next to it.
                context.stroke(path, with: .color(baseColor.opacity(isConnected ? 0.45 : 0.06)),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            } else {
                context.stroke(path, with: .color(baseColor.opacity(isConnected ? 0.5 : 0.07)), lineWidth: 1.5)
            }

            // Arrowhead at the target end points along the flow (reads: into the
            // cron; writes/delivers: into the resource/sink), so direction is
            // legible without reading the edge label. Containment edges get no
            // arrowhead — there is no direction of travel to indicate.
            let targetR = viewModel.radius(forKind: viewModel.simNodes[ti].kind)
            if !isContainment, len > targetR + 6 {
                drawArrowhead(context: context, tip: tp, control: ctrl,
                              backoff: targetR + 2, color: baseColor.opacity(isConnected ? 0.7 : 0.07))
            }

            // The type text is redundant with color + arrow + legend in the
            // resting view; show it only for the focused subgraph on selection.
            if hasSelection && isConnected {
                context.draw(
                    Text(type)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(baseColor.opacity(0.85)),
                    at: ctrl, anchor: .center
                )
            }
        }
    }

    /// A small filled triangle pointing along the quad curve's tangent at the
    /// target (`2·(tip − control)`), backed off the node body so it sits just
    /// outside the glyph.
    private func drawArrowhead(context: GraphicsContext, tip: CGPoint, control: CGPoint,
                               backoff: CGFloat, color: Color) {
        let tangent = CGPoint(x: tip.x - control.x, y: tip.y - control.y)
        let tlen = max(hypot(tangent.x, tangent.y), 0.001)
        let ux = tangent.x / tlen, uy = tangent.y / tlen
        let apex = CGPoint(x: tip.x - ux * backoff, y: tip.y - uy * backoff)
        let size: CGFloat = 6.5
        let base = CGPoint(x: apex.x - ux * size, y: apex.y - uy * size)
        let half = size * 0.6
        var arrow = Path()
        arrow.move(to: apex)
        arrow.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        arrow.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    private func drawNodes(context: GraphicsContext, hasSelection: Bool) {
        for index in viewModel.drawOrder {
            guard viewModel.simNodes.indices.contains(index) else { continue }
            let node = viewModel.simNodes[index]
            let pos = node.position
            let isSelected = viewModel.selectedNodeIndex == index
            let isHovered = viewModel.hoveredNodeIndex == index
            let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
            let baseOpacity: CGFloat = isConnected ? 1.0 : 0.18
            let r = viewModel.radius(forKind: node.kind)
            let base = viewModel.nodeColor(kind: node.kind, type: node.type, label: node.label)
            let glyph = viewModel.glyph(forKind: node.kind)

            if isConnected {
                // The halo stays a round radial glow behind every glyph — a soft
                // light source reads the same for any silhouette and keeps the
                // shape itself the only kind cue.
                let glowR = r * (isSelected || isHovered ? 3.4 : 2.4)
                let glowRect = CGRect(x: pos.x - glowR, y: pos.y - glowR, width: glowR * 2, height: glowR * 2)
                let glow = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [base.opacity(isSelected || isHovered ? 0.45 : 0.22), base.opacity(0)]),
                    center: pos, startRadius: 0, endRadius: glowR
                )
                context.fill(Path(ellipseIn: glowRect), with: glow)
            }

            if isSelected || isHovered {
                let ringR = r + (isSelected ? 5 : 3)
                let ringRect = CGRect(x: pos.x - ringR, y: pos.y - ringR, width: ringR * 2, height: ringR * 2)
                context.stroke(
                    CronNodeGlyphShape(glyph: glyph).path(in: ringRect),
                    with: .color(.white.opacity(isSelected ? 0.85 : 0.5)),
                    lineWidth: isSelected ? 2 : 1.2
                )
            }

            let nodeRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
            let bodyPath = CronNodeGlyphShape(glyph: glyph).path(in: nodeRect)
            let bodyShading = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [base.opacity(baseOpacity), base.opacity(baseOpacity * 0.62)]),
                center: CGPoint(x: pos.x - r * 0.3, y: pos.y - r * 0.3),
                startRadius: 0, endRadius: r * 1.4
            )
            context.fill(bodyPath, with: bodyShading)
            context.stroke(
                bodyPath,
                with: .color(.white.opacity(isConnected ? 0.45 : 0.15)),
                lineWidth: 0.8
            )
            if node.kind == "service", let health = viewModel.serviceHealth(forNodeID: node.id) {
                let statusColor: Color = health.isHealthy
                    ? .green
                    : (health.isUnhealthy ? .red : .orange)
                let dotRadius: CGFloat = 3.5
                let dotCenter = CGPoint(x: pos.x + r * 0.72, y: pos.y - r * 0.72)
                let dotRect = CGRect(
                    x: dotCenter.x - dotRadius,
                    y: dotCenter.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                context.fill(Path(ellipseIn: dotRect), with: .color(statusColor.opacity(baseOpacity)))
                context.stroke(Path(ellipseIn: dotRect), with: .color(Theme.background), lineWidth: 1)
            }
        }
    }

    /// One placed label: everything needed to draw it, plus the priority that
    /// decides who wins the space when two would overlap.
    private struct LabelCandidate {
        let text: String
        let screenPos: CGPoint
        let isAnchor: Bool
        /// 0 = anchor, 1 = neighbor of the anchor, 2 = everything else. Lower
        /// wins, and 0/1 always draw (never dropped for a collision).
        let rank: Int
        /// Draw-order tiebreak so the sort is stable within a rank.
        let order: Int
    }

    private func drawLabels(context: inout GraphicsContext, size: CGSize, hasSelection: Bool) {
        let neighborSet: Set<Int> = hasSelection ? Set(viewModel.selectedNodeNeighbors()) : []

        // Gather every visible label as a candidate first, so we can rank them
        // and drop collisions rather than painting names on top of each other.
        var candidates: [LabelCandidate] = []
        for (index, node) in viewModel.simNodes.enumerated() {
            let isConnected = !hasSelection || viewModel.isNodeConnectedToSelection(index)
            guard isConnected else { continue }
            let isAnchor = viewModel.selectedNodeIndex == index || viewModel.hoveredNodeIndex == index
            let isNeighbor = neighborSet.contains(index)
            if viewModel.zoom < 0.7 && !isAnchor && !isNeighbor { continue }
            let r = viewModel.radius(forKind: node.kind)
            let screenPos = CGPoint(
                x: node.position.x * viewModel.zoom + viewModel.panOffset.width + r * viewModel.zoom + 4,
                y: node.position.y * viewModel.zoom + viewModel.panOffset.height
            )
            guard screenPos.x > -80, screenPos.x < size.width + 80,
                  screenPos.y > -20, screenPos.y < size.height + 20 else { continue }
            candidates.append(LabelCandidate(
                // The hull above the node already names its category, so the
                // label carries only the part the hull doesn't.
                text: viewModel.displayLabel(forKind: node.kind, label: node.label),
                screenPos: screenPos,
                isAnchor: isAnchor,
                rank: isAnchor ? 0 : (isNeighbor ? 1 : 2),
                order: index
            ))
        }
        // Anchor first, then its neighbors, then the rest — so the labels you're
        // actually looking at claim their space before the ambient ones.
        candidates.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }

        // Screen rects already taken. A lower-priority label whose box would
        // overlap one of these is skipped: in a tight cluster of similarly named
        // tables you get a legible subset, not a smear. Zoom in or hover a node
        // to surface the ones that dropped.
        var placed: [CGRect] = []
        for candidate in candidates {
            let label = Text(candidate.text)
                .font(.system(size: candidate.isAnchor ? 12 : 11, weight: candidate.isAnchor ? .semibold : .medium))
                .foregroundColor(.white.opacity(candidate.isAnchor ? 1.0 : 0.82))
            let resolved = context.resolve(label)
            let measured = resolved.measure(in: CGSize(width: 1000, height: 1000))
            // `.leading` anchor: the box grows right from screenPos, centered on it.
            let box = CGRect(
                x: candidate.screenPos.x,
                y: candidate.screenPos.y - measured.height / 2,
                width: measured.width,
                height: measured.height
            )
            let collisionBox = box.insetBy(dx: -3, dy: -1)
            let mustShow = candidate.rank <= 1
            if !mustShow, placed.contains(where: { $0.intersects(collisionBox) }) { continue }
            placed.append(collisionBox)
            // A dark rounded plate under the text keeps it readable over edges,
            // node glows, and any higher-priority label it still sits beside.
            context.fill(
                Path(roundedRect: box.insetBy(dx: -4, dy: -2), cornerRadius: 4),
                with: .color(Theme.background.opacity(0.72))
            )
            context.draw(resolved, at: candidate.screenPos, anchor: .leading)
        }
    }
}
