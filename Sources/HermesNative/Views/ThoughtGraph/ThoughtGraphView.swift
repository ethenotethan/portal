import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - ThoughtGraphView

/// Interactive DAG canvas that visualizes live agent tool-call chains
/// during a streaming turn.  Uses a SwiftUI `Canvas` for efficient
/// rendering of nodes and edges, with pan/zoom controls and a slide-in
/// detail panel for inspecting individual tool calls.
///
/// ## Architecture
/// - **Layout**: Delegated to `ThoughtGraphLayoutEngine` (layered DAG).
/// - **Edges**: Dashed quadratic bezier curves behind nodes.
/// - **Nodes**: Rendered as pre-snapshot `Image` entries via `ImageRenderer`
///   to avoid constructing SwiftUI view trees inside the Canvas draw closure.
/// - **Interaction**: macOS uses `GraphMouseInterceptor` (NSView overlay);
///   iOS uses `DragGesture` + `MagnificationGesture`.
struct ThoughtGraphView: View {

    // MARK: - Observed State

    @ObservedObject var engine: ThoughtGraphLayoutEngine

    /// All nodes currently in the graph — changed externally as new
    /// tool.start / tool.complete events arrive.
    let nodes: [ThoughtGraphNode]

    /// Whether the conversation turn is still streaming.  Controls the
    /// live indicator in the header.
    let isStreaming: Bool

    // MARK: - Derived Node Data (computed once per view update)

    /// `nodes` filtered by mode, cached so body evaluations don't re-filter.
    private let toolNodes: [ThoughtGraphNode]
    private let reasoningNodes: [ThoughtGraphNode]

    /// Lookup from node ID → node for O(1) access in the Canvas draw path.
    private let nodeIndex: [String: ThoughtGraphNode]

    private let runningToolCount: Int
    private let runningReasoningCount: Int

    init(engine: ThoughtGraphLayoutEngine, nodes: [ThoughtGraphNode], isStreaming: Bool) {
        self.engine = engine
        self.nodes = nodes
        self.isStreaming = isStreaming
        let toolNodes = nodes.filter { $0.name != "reasoning" }
        let reasoningNodes = nodes.filter { $0.name == "reasoning" }
        self.toolNodes = toolNodes
        self.reasoningNodes = reasoningNodes
        self.nodeIndex = Dictionary(
            nodes.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.runningToolCount = toolNodes.filter { $0.status == .running }.count
        self.runningReasoningCount = reasoningNodes.filter { $0.status == .running }.count
    }

    // MARK: - Local State

    @State private var panOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var selectedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var showInferredEdges: Bool = true
    @State private var isFullScreen = false
    @State private var mode: GraphMode = .tools

    enum GraphMode: String, CaseIterable { case tools = "Tools", reasoning = "Reasoning" }

    private var activeNodes: [ThoughtGraphNode] {
        mode == .tools ? toolNodes : reasoningNodes
    }

    private var runningCount: Int {
        mode == .tools ? runningToolCount : runningReasoningCount
    }

    /// Layout trigger key — changes when the active node set changes,
    /// either via mode switch or node arrival/removal.
    private var layoutKey: String { "\(mode.rawValue)-\(activeNodes.count)" }

    // MARK: - Expand Button

    // ── Mouse interaction (macOS) ──
    #if os(macOS)
    @State private var mouseState = MouseState.idle
    @State private var dragStartPan: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero
    private enum MouseState { case idle, deciding, panning }
    #endif

    // ── Pinch (iOS / shared) ──
    @State private var lastPinchScale: CGFloat = 1.0

    // ── Canvas size (set once from GeometryReader) ──
    @State private var canvasSize: CGSize = .zero

    // ── Cached node snapshots ──
    @State private var snapshotCache: [String: Image] = [:]

    // ── Running-node pulse phase (advanced by the 10Hz timer) ──
    @State private var pulsePhase: TimeInterval = Date.now.timeIntervalSinceReferenceDate

    // ── Transitions ──
    @State private var previousNodeIDs: Set<String> = []

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    // ── Background ──
                    Theme.background
                        .ignoresSafeArea()

                    // ── Graph canvas ──
                    graphCanvas

                    // ── Empty state ──
                    if activeNodes.isEmpty {
                        emptyState
                    }

                    // ── Mouse interceptor (macOS) ──
                    #if os(macOS)
                    GraphMouseInterceptor(
                        onMouseDown: { pt in handleMouseDown(at: pt) },
                        onMouseDragged: { pt in handleMouseDragged(to: pt) },
                        onMouseUp: { pt in handleMouseUp(at: pt) },
                        onScrollWheel: { delta in
                            panOffset.width += delta.width
                            panOffset.height += delta.height
                        },
                        onMouseMoved: { pt in
                            if mouseState == .idle {
                                hoveredNodeID = hitTest(point: pt)
                            }
                        },
                        onMouseExited: {
                            hoveredNodeID = nil
                        }
                    )
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Detail popover (right panel) ──
                if let selID = selectedNodeID,
                   let node = nodeIndex[selID] {
                    detailPopover(node: node)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        // ── iOS gestures ──
        #if !os(macOS)
        .gesture(iosDragGesture)
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    let targetZoom = lastPinchScale * value
                    let clamped = max(0.5, min(4.0, targetZoom))
                    let oldZoom = zoom
                    guard abs(clamped - oldZoom) > 0.001 else { return }
                    let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    zoomAtPoint(factor: clamped / oldZoom, around: c)
                }
                .onEnded { _ in
                    lastPinchScale = zoom
                }
        )
        #endif

        // ── Header overlay ──
        .overlay(alignment: .top) {
            headerBar
        }

        // ── Controls overlay ──
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                // Inferred edges toggle
                inferredEdgesToggle
                zoomControls
            }
        }

        // ── Double-tap reset (macOS) ──
        #if os(macOS)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                zoom = 1.0
                panOffset = .zero
            }
        }
        #endif

        .onAppear {
            previousNodeIDs = Set(activeNodes.map(\.id))
            engine.layout(nodes: activeNodes)
        }
        .onChange(of: layoutKey) { _, _ in
            engine.layout(nodes: activeNodes)
            let newIDs = Set(activeNodes.map(\.id))
            let appeared = newIDs.subtracting(previousNodeIDs)
            // Animate new nodes: briefly reset cache so they redraw fresh.
            // The actual scale-up is handled by the Canvas' draw closure
            // when a node is "new".
            for id in appeared { invalidateSnapshots(for: id) }
            previousNodeIDs = newIDs
        }
        .onChange(of: isFullScreen) { _, fullScreen in
            if fullScreen {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    zoom = 1.0
                    panOffset = .zero
                }
            }
        }
        .onChange(of: selectedNodeID) { oldID, newID in
            // Cache keys encode selection state, so only the two affected
            // nodes' snapshot variants need pruning.
            if let oldID { invalidateSnapshots(for: oldID) }
            if let newID { invalidateSnapshots(for: newID) }
        }
        .onChange(of: zoom) { _, _ in lastPinchScale = zoom }

        // ── Periodic refresh for running nodes (pulsing) ──
        .onReceive(
            Timer.publish(every: 1.0 / 10.0, on: .main, in: .common).autoconnect()
        ) { now in
            // Advance the pulse phase only while nodes are running.  The
            // Canvas reads `pulsePhase`, so this triggers a cheap redraw of
            // cached snapshots instead of invalidating and re-rendering
            // every node image through ImageRenderer.
            if runningCount > 0 {
                pulsePhase = now.timeIntervalSinceReferenceDate
            }
        }

        // Full-screen overlay
        .overlay {
            if isFullScreen {
                graphContent
            }
        }
    }

    @ViewBuilder
    private var graphContent: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ZStack {
                    Theme.background
                        .ignoresSafeArea()

                    graphCanvas

                    if activeNodes.isEmpty {
                        emptyState
                    }

                    #if os(macOS)
                    GraphMouseInterceptor(
                        onMouseDown: { pt in handleMouseDown(at: pt) },
                        onMouseDragged: { pt in handleMouseDragged(to: pt) },
                        onMouseUp: { pt in handleMouseUp(at: pt) },
                        onScrollWheel: { delta in
                            panOffset.width += delta.width
                            panOffset.height += delta.height
                        },
                        onMouseMoved: { pt in
                            if mouseState == .idle {
                                hoveredNodeID = hitTest(point: pt)
                            }
                        },
                        onMouseExited: { hoveredNodeID = nil }
                    )
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let selID = selectedNodeID,
                   let node = nodeIndex[selID] {
                    detailPopover(node: node)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Graph Canvas

    @ViewBuilder
    private var graphCanvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let selectedID = selectedNodeID
                // Breathing opacity for running nodes (0.6…1.0, 1.5s period).
                // Reading `pulsePhase` ties the Canvas to the 10Hz timer so
                // cached snapshots redraw cheaply instead of re-rendering.
                let pulse = 0.8 + 0.2 * sin(pulsePhase * (2 * .pi / 1.5))

                context.translateBy(x: size.width / 2 + panOffset.width,
                                    y: 80 + panOffset.height)
                context.scaleBy(x: zoom, y: zoom)

                // ── 1. Draw edges (behind nodes) ──
                if showInferredEdges {
                for (parentID, childID) in engine.edges {
                    let isHighlighted: Bool
                    if let selID = selectedID {
                        isHighlighted = (parentID == selID || childID == selID)
                    } else {
                        isHighlighted = true
                    }

                    let edgeOpacity: CGFloat = isHighlighted ? 0.35 : 0.08
                    let edgeWidth: CGFloat = isHighlighted ? 1.8 : 0.8

                    let path = engine.edgePath(from: parentID, to: childID)
                    if !path.isEmpty {
                        context.stroke(
                            path,
                            with: .color(Theme.accent.opacity(edgeOpacity)),
                            style: StrokeStyle(
                                lineWidth: edgeWidth,
                                dash: [6, 5],
                                dashPhase: 0
                            )
                        )
                    }
                }
                }

                // ── 2. Draw node glow (running nodes only) ──
                for layout in engine.layouts {
                    guard let node = nodeIndex[layout.nodeID],
                          node.status == .running else { continue }
                    let glowR: CGFloat = 36
                    let cx = layout.x
                    let cy = layout.y
                    let rect = CGRect(
                        x: cx - glowR, y: cy - glowR,
                        width: glowR * 2, height: glowR * 2
                    )
                    let glow = GraphicsContext.Shading.radialGradient(
                        Gradient(colors: [
                            Theme.warning.opacity(0.25 * pulse),
                            Theme.warning.opacity(0.0),
                        ]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0,
                        endRadius: glowR
                    )
                    context.fill(Path(ellipseIn: rect), with: glow)
                }

                // ── 3. Draw nodes (prerendered images) ──
                for layout in engine.layouts {
                    guard let node = nodeIndex[layout.nodeID] else { continue }
                    let isSelected = selectedNodeID == node.id
                    let isHovered = hoveredNodeID == node.id

                    // Pulse running nodes by modulating draw opacity over the
                    // cached snapshot — the cache itself stays intact.
                    var nodeContext = context
                    if node.status == .running {
                        nodeContext.opacity = pulse
                    }

                    if let cached = snapshotCache[node.cacheKey(isSelected: isSelected, hovered: isHovered)] {
                        nodeContext.draw(cached, at: CGPoint(x: layout.x, y: layout.y))
                    } else {
                        // Render a fresh snapshot
                        let view = ThoughtGraphNodeView(
                            node: node, layout: layout,
                            isSelected: isSelected, isHovered: isHovered
                        )
                        #if os(macOS)
                        let renderer = ImageRenderer(
                            content: view
                                .frame(width: layout.width, height: layout.height)
                        )
                        if let nsImage = renderer.nsImage {
                            let img = Image(nsImage: nsImage)
                            snapshotCache[node.cacheKey(isSelected: isSelected, hovered: isHovered)] = img
                            nodeContext.draw(img, at: CGPoint(x: layout.x, y: layout.y))
                        }
                        #else
                        let renderer = ImageRenderer(
                            content: view
                                .frame(width: layout.width, height: layout.height)
                        )
                        if let uiImage = renderer.uiImage {
                            let img = Image(uiImage: uiImage)
                            snapshotCache[node.cacheKey(isSelected: isSelected, hovered: isHovered)] = img
                            nodeContext.draw(img, at: CGPoint(x: layout.x, y: layout.y))
                        }
                        #endif
                    }
                }

                // ── 4. Completed checkmark overlay (screen-space) ──
                // Small green check drawn on top-right of completed nodes,
                // independent of zoom to stay readable.
                context.transform = .identity
                let completedNodes = engine.layouts.compactMap { layout -> (ThoughtGraphLayout, ThoughtGraphNode)? in
                    guard let n = nodeIndex[layout.nodeID],
                          n.status == .completed else { return nil }
                    return (layout, n)
                }
                for (layout, node) in completedNodes {
                    let screenX = (layout.x + layout.width / 2 + 4) * zoom
                        + canvasSize.width / 2 + panOffset.width
                    let screenY = (layout.y - layout.height / 2 - 4) * zoom
                        + 80 + panOffset.height

                    guard screenX > -20, screenX < canvasSize.width + 20,
                          screenY > -20, screenY < canvasSize.height + 20 else { continue }

                    // Dim if another node is selected
                    let dim = (selectedNodeID != nil && selectedNodeID != node.id)
                    context.draw(
                        Text(Image(systemName: "checkmark.circle.fill"))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.success.opacity(dim ? 0.25 : 0.85)),
                        at: CGPoint(x: screenX, y: screenY),
                        anchor: .center
                    )
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isStreaming
                  ? "arrow.triangle.2.circlepath"
                  : "square.stack.3d.up")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)

            Text(isStreaming ? "Waiting for agent..." : "No tool calls yet")
                .font(.headline)
                .foregroundStyle(Theme.secondary)

            if isStreaming {
                Text("Tool calls will appear here as the agent works")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Agent Thought Graph")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)

                if isStreaming {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Theme.warning.opacity(0.5), lineWidth: 3)
                                .scaleEffect(1.8)
                                .opacity(0.5)
                        )
                    Text("streaming")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.success)
                    Text("complete")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }

                if runningCount > 0 {
                    Text("\(runningCount) tools running")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                }

                Spacer()

                // Mode selector
                Picker("", selection: $mode) {
                    ForEach(GraphMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                // Expand
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isFullScreen.toggle()
                    }
                } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }

            // Legend
            HStack(spacing: 12) {
                legendItem(icon: "arrow.triangle.2.circlepath", color: Theme.warning, label: "running")
                legendItem(icon: "checkmark.circle.fill", color: Theme.success, label: "completed")
                legendItem(icon: "xmark.circle.fill", color: Color.red, label: "error")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func legendItem(icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Zoom Controls

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button {
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                withAnimation(.easeOut(duration: 0.22)) {
                    zoomAtPoint(factor: 0.8, around: c)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Text("\(Int(zoom * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(minWidth: 32)

            Button {
                let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                withAnimation(.easeOut(duration: 0.22)) {
                    zoomAtPoint(factor: 1.25, around: c)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    zoom = 1.0
                    panOffset = .zero
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(Theme.secondary)
        .padding(10)
        .background(
            Theme.surface.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .padding(12)
    }

    // MARK: - Inferred Edges Toggle

    private var inferredEdgesToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                showInferredEdges.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showInferredEdges ? "arrow.triangle.branch" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                Text("Edges")
                    .font(.caption2)
                if showInferredEdges {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(showInferredEdges ? Theme.primary : Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                showInferredEdges
                    ? Theme.accent.opacity(0.15)
                    : Theme.surface.opacity(0.6),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.borderless)
        .padding(.trailing, 12)
    }

    // MARK: - Detail Popover

    @ViewBuilder
    private func detailPopover(node: ThoughtGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack {
                ThoughtGraphNodeView(
                    node: node,
                    layout: ThoughtGraphLayout(
                        nodeID: node.id, x: 0, y: 0,
                        width: ThoughtGraphLayoutEngine.nodeSize.width,
                        height: ThoughtGraphLayoutEngine.nodeSize.height
                    ),
                    isSelected: false, isHovered: false
                )
                .frame(width: ThoughtGraphLayoutEngine.nodeSize.width,
                       height: ThoughtGraphLayoutEngine.nodeSize.height)
                .scaleEffect(0.9)

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedNodeID = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)

            Divider()
                .padding(.vertical, 10)
                .padding(.horizontal, 14)

            // ── Status ──
            HStack(spacing: 6) {
                statusBadge(for: node.status)
                Text(node.status.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.primary)
                if let dur = node.durationSeconds {
                    Text("· \(DurationFormatter.short(dur))")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 14)

            // ── Context ──
            if let ctx = node.context {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 12)
                    Text(ctx)
                        .font(.caption)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(6)
                }
                .padding(.horizontal, 14)
            }

            // ── Summary ──
            if let sum = node.summary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 12)
                    Text(sum)
                        .font(.caption)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(8)
                }
                .padding(.horizontal, 14)
            }

            // ── Inline diff (expandable placeholder) ──
            // Reserved for future: expandable diff viewer

            Spacer()

            // ── Jump to tool button ──
            Button {
                // Reserved: jump to tool in chat
            } label: {
                Label("Jump to tool in chat", systemImage: "arrow.turn.up.right")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .ignoresSafeArea(.container, edges: .vertical)
    }

    private func statusBadge(for status: ThoughtNodeStatus) -> some View {
        Circle()
            .fill(statusColor(for: status))
            .frame(width: 8, height: 8)
    }

    private func statusColor(for status: ThoughtNodeStatus) -> Color {
        switch status {
        case .running:  return Theme.warning
        case .completed: return Theme.success
        case .error:     return .red
        }
    }

    // MARK: - Hit Testing

    /// Convert a point in view-space to a node ID, if any.
    private func hitTest(point: CGPoint) -> String? {
        let canvasCenterX = canvasSize.width / 2 + panOffset.width
        let canvasCenterY: CGFloat = 80 + panOffset.height

        for layout in engine.layouts {
            // Transform layout coords to screen space
            let sx = layout.x * zoom + canvasCenterX
            let sy = layout.y * zoom + canvasCenterY
            let sw = layout.width * zoom
            let sh = layout.height * zoom
            let rect = CGRect(x: sx - sw / 2, y: sy - sh / 2, width: sw, height: sh)

            if rect.contains(point) {
                return layout.nodeID
            }
        }
        return nil
    }

    // MARK: - Zoom

    private func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom
        let newZoom = max(0.5, min(4.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    // MARK: - Snapshots

    /// Remove all cached snapshot variants (selected/hovered/status) for one node.
    private func invalidateSnapshots(for nodeID: String) {
        let prefix = "\(nodeID)-"
        for key in snapshotCache.keys where key.hasPrefix(prefix) {
            snapshotCache.removeValue(forKey: key)
        }
    }

    // MARK: - Mouse Handlers (macOS)

    #if os(macOS)
    private func handleMouseDown(at pt: CGPoint) {
        mouseState = .deciding
        dragStartPan = panOffset
        dragStartPoint = pt
    }

    private func handleMouseDragged(to pt: CGPoint) {
        let dx = pt.x - dragStartPoint.x
        let dy = pt.y - dragStartPoint.y
        let dist = hypot(dx, dy)

        switch mouseState {
        case .deciding:
            if dist > 5 {
                mouseState = .panning
            }
        case .panning:
            panOffset = CGSize(
                width: dragStartPan.width + dx,
                height: dragStartPan.height + dy
            )
        case .idle:
            break
        }
    }

    private func handleMouseUp(at pt: CGPoint) {
        if mouseState == .deciding {
            // It's a tap — select node if hit
            if let nodeID = hitTest(point: dragStartPoint) {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedNodeID = (selectedNodeID == nodeID) ? nil : nodeID
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedNodeID = nil
                }
            }
        }
        mouseState = .idle
    }
    #endif

    // MARK: - iOS Drag Gesture

    #if !os(macOS)
    @State private var iosMouseState = IosMouseState.idle
    @State private var iosDragStartPan: CGSize = .zero
    @State private var iosDragStartPoint: CGPoint = .zero

    private enum IosMouseState { case idle, deciding, panning }

    private var iosDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                switch iosMouseState {
                case .idle:
                    iosMouseState = .deciding
                    iosDragStartPan = panOffset
                    iosDragStartPoint = value.startLocation
                case .deciding:
                    let dist = hypot(value.translation.width, value.translation.height)
                    if dist > 5 {
                        iosMouseState = .panning
                    }
                case .panning:
                    panOffset = CGSize(
                        width: iosDragStartPan.width + value.translation.width,
                        height: iosDragStartPan.height + value.translation.height
                    )
                }
            }
            .onEnded { value in
                if iosMouseState == .deciding {
                    // Tap
                    if let nodeID = hitTest(point: value.startLocation) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedNodeID = (selectedNodeID == nodeID) ? nil : nodeID
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedNodeID = nil
                        }
                    }
                }
                iosMouseState = .idle
            }
    }
    #endif
}

// MARK: - Cache Key Helper

private extension ThoughtGraphNode {
    /// Produce a stable cache key for the snapshot dictionary.
    func cacheKey(isSelected: Bool, hovered: Bool) -> String {
        "\(id)-sel\(isSelected)-hov\(hovered)-\(status.rawValue)"
    }
}

// MARK: - Status Display Name

private extension ThoughtNodeStatus {
    var displayName: String {
        switch self {
        case .running:  return "Running"
        case .completed: return "Completed"
        case .error:     return "Error"
        }
    }
}

// MARK: - Previews

#if DEBUG
struct ThoughtGraphViewPreviews: PreviewProvider {
    @MainActor
    static var previews: some View {
        let engine = ThoughtGraphLayoutEngine()
        let sampleNodes = makeSampleNodes()
        engine.layout(nodes: sampleNodes)

        return ThoughtGraphView(
            engine: engine,
            nodes: sampleNodes,
            isStreaming: true
        )
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
    }

    @MainActor
    static func makeSampleNodes() -> [ThoughtGraphNode] {
        let n1 = ThoughtGraphNode(
            id: "t1", name: "search_files",
            context: "Searching for DAG layout papers...",
            isComplete: true,
            durationSeconds: 0.82,
            depth: 0
        )
        let n2 = ThoughtGraphNode(
            id: "t2", name: "read_file",
            context: "Reading ThoughtGraphLayoutEngine.swift",
            summary: "320 lines, 12 KB",
            isComplete: true,
            durationSeconds: 0.34,
            depth: 1,
            parentIDs: ["t1"]
        )
        let n3 = ThoughtGraphNode(
            id: "t3", name: "read_file",
            context: "Reading WikiGraphView.swift for pattern reference",
            summary: "775 lines, 31 KB",
            isComplete: true,
            durationSeconds: 0.41,
            depth: 1,
            parentIDs: ["t1"]
        )
        let n4 = ThoughtGraphNode(
            id: "t4", name: "write_file",
            context: "Creating ThoughtGraphView.swift...",
            isComplete: false,
            depth: 2,
            parentIDs: ["t2", "t3"]
        )
        let n5 = ThoughtGraphNode(
            id: "t5", name: "write_file",
            context: "Creating ThoughtGraphNodeView.swift...",
            isComplete: false,
            depth: 2,
            parentIDs: ["t2", "t3"]
        )
        return [n1, n2, n3, n4, n5]
    }
}
#endif
