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
                    categoryLegendRows
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
                    Text(node.kind == "cron" ? "cron job" : node.type)
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

                drawEdges(context: context, hasSelection: hasSelection)
                drawNodes(context: context, hasSelection: hasSelection)

                guard mouseState != .panning && mouseState != .draggingNode else { return }
                context.transform = .identity
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

            var path = Path()
            path.move(to: sp)
            path.addQuadCurve(to: tp, control: ctrl)
            context.stroke(path, with: .color(baseColor.opacity(isConnected ? 0.5 : 0.07)), lineWidth: 1.5)

            if isConnected {
                context.draw(
                    Text(type)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(baseColor.opacity(0.85)),
                    at: ctrl, anchor: .center
                )
            }
        }
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
            let base = viewModel.nodeColor(kind: node.kind, label: node.label)
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
        }
    }

    private func drawLabels(context: inout GraphicsContext, size: CGSize, hasSelection: Bool) {
        let neighborSet: Set<Int> = hasSelection ? Set(viewModel.selectedNodeNeighbors()) : []
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
            context.draw(
                Text(node.label)
                    .font(.system(size: isAnchor ? 12 : 11, weight: isAnchor ? .semibold : .medium))
                    .foregroundColor(.white.opacity(isAnchor ? 1.0 : 0.82)),
                at: screenPos, anchor: .leading
            )
        }
    }
}

// MARK: - CronNodeGlyphShape

/// The per-kind node silhouette, inscribed in its bounding rect. One source of
/// truth for the shape a kind draws as, shared by the `Canvas` node bodies and
/// selection rings and by the legend/detail swatches — so the key on the graph
/// shows exactly the outline it labels. Kind → glyph mapping lives on the view
/// model (`CronGraphViewModel.glyph(forKind:)`); this only renders it.
internal struct CronNodeGlyphShape: Shape {
    internal let glyph: CronGraphViewModel.NodeGlyph

    internal func path(in rect: CGRect) -> Path {
        switch glyph {
        case .circle:
            return Path(ellipseIn: rect)
        case .triangle:
            // Apex up, base along the bottom — an input pointing into the graph.
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .cylinder:
            return Self.cylinderPath(in: rect)
        }
    }

    /// A database can: an elliptical lid, straight sides, and a front-bulging
    /// bottom. The body subpath and the full top ellipse are unioned in one
    /// `Path` (non-zero winding) so it fills as a solid store glyph.
    private static func cylinderPath(in rect: CGRect) -> Path {
        let capRy = rect.height * 0.22
        let topY = rect.minY + capRy
        let botY = rect.maxY - capRy
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: topY))
        path.addLine(to: CGPoint(x: rect.minX, y: botY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: botY),
                          control: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: topY),
                          control: CGPoint(x: rect.midX, y: topY + capRy))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: capRy * 2))
        return path
    }
}
