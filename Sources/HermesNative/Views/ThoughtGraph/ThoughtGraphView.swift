import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - ThoughtGraphView

/// Interactive swimlane/timeline canvas that visualizes the live agent react
/// loop: reasoning beats and tool calls flow down the main lane, and every
/// spawned subagent opens its own lane whose loop runs in parallel.
///
/// ## Architecture
/// - **Layout**: `ThoughtGraphLayoutEngine` (lanes × chronological rows).
/// - **Motion**: node positions are lerped toward layout targets on a 30Hz
///   tick, new nodes scale/fade in, new edges draw in via path trim, and
///   flow particles run along edges into running nodes.
/// - **Nodes**: pre-snapshot `Image` cards via `ImageRenderer` at readable
///   zoom; compact category dots below the semantic-zoom threshold.
/// - **Camera**: optional follow mode tails the newest activity while
///   streaming; any manual pan disengages it.
/// - **Interaction**: macOS `GraphMouseInterceptor`; iOS drag + pinch.
struct ThoughtGraphView: View {

    // MARK: - Observed State

    @ObservedObject var engine: ThoughtGraphLayoutEngine

    /// All nodes currently in the graph — changed externally as new
    /// tool/reasoning/subagent events arrive.
    let nodes: [ThoughtGraphNode]

    /// Whether the conversation turn is still streaming.
    let isStreaming: Bool

    /// Invoked with a tool-call ID when the user taps "Jump to tool in chat".
    var onJumpToTool: ((String) -> Void)?

    /// Live cost/token rollup for the current turn. nil hides the chip.
    var usageSummary: String?

    // MARK: - Derived Node Data (computed once per view update)

    private let nodeIndex: [String: ThoughtGraphNode]
    private let runningCount: Int

    init(
        engine: ThoughtGraphLayoutEngine,
        nodes: [ThoughtGraphNode],
        isStreaming: Bool,
        usageSummary: String? = nil,
        onJumpToTool: ((String) -> Void)? = nil
    ) {
        self.engine = engine
        self.nodes = nodes
        self.isStreaming = isStreaming
        self.usageSummary = usageSummary
        self.onJumpToTool = onJumpToTool
        self.nodeIndex = Dictionary(
            nodes.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.runningCount = nodes.filter { $0.status == .running }.count
    }

    // MARK: - Local State

    @State private var panOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var selectedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var showReasoningBeats: Bool = true
    @State private var collapsedAgentIDs: Set<String> = []

    /// Camera tails the newest activity while streaming until the user pans.
    @State private var autoFollow: Bool = true

    // ── Motion state (advanced by the 30Hz tick) ──
    @State private var animPositions: [String: CGPoint] = [:]
    @State private var nodeAppearTimes: [String: TimeInterval] = [:]
    @State private var edgeAppearTimes: [String: TimeInterval] = [:]
    @State private var now: TimeInterval = Date.now.timeIntervalSinceReferenceDate

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

    // MARK: - Constants

    /// Below this zoom nodes render as compact category dots.
    private static let semanticZoomThreshold: CGFloat = 0.55
    private static let appearDuration: TimeInterval = 0.3
    private static let edgeDrawDuration: TimeInterval = 0.35
    /// World-space Y anchor: fraction of the canvas height where the newest
    /// node sits while following.
    private static let followAnchor: CGFloat = 0.68

    // MARK: - Visible Nodes

    /// Nodes after collapse/reasoning filtering — what actually lays out.
    private var visibleNodes: [ThoughtGraphNode] {
        nodes.filter { node in
            if !showReasoningBeats && node.category == .reasoning { return false }
            if let owner = node.ownerAgentID, collapsedAgentIDs.contains(owner) { return false }
            return true
        }
    }

    /// Loop-step counts per agent, for collapsed badges and the detail panel.
    private var stepCountByAgentID: [String: Int] {
        nodes.reduce(into: [:]) { counts, node in
            if let owner = node.ownerAgentID { counts[owner, default: 0] += 1 }
        }
    }

    /// Layout trigger key — changes when the visible node set changes.
    private var layoutKey: String {
        "\(visibleNodes.count)-\(showReasoningBeats)-\(collapsedAgentIDs.sorted().joined(separator: ","))"
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ZStack {
                    Theme.background
                        .ignoresSafeArea()

                    graphCanvas

                    if visibleNodes.isEmpty {
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
                            autoFollow = false
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
                    let clamped = max(0.25, min(4.0, targetZoom))
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
        .overlay(alignment: .bottomTrailing) {
            HStack(alignment: .bottom, spacing: 8) {
                reasoningToggle
                zoomControls
            }
        }

        // ── Follow pill (re-engage the camera) ──
        .overlay(alignment: .bottomLeading) {
            if !autoFollow && isStreaming {
                followPill
            }
        }

        // ── Double-tap reset (macOS) ──
        #if os(macOS)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                zoom = 1.0
                panOffset = .zero
            }
            autoFollow = true
        }
        #endif

        .onAppear {
            engine.layout(nodes: visibleNodes)
            seedMotionState(animated: false)
        }
        .onChange(of: layoutKey) { _, _ in
            engine.layout(nodes: visibleNodes)
            seedMotionState(animated: true)
        }
        .onChange(of: selectedNodeID) { oldID, newID in
            if let oldID { invalidateSnapshots(for: oldID) }
            if let newID { invalidateSnapshots(for: newID) }
        }
        .onChange(of: zoom) { _, _ in lastPinchScale = zoom }

        // ── 30Hz motion tick: lerp, pulse, particles, follow-cam ──
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { tick in
            advanceMotion(to: tick.timeIntervalSinceReferenceDate)
        }
    }

    // MARK: - Motion

    /// Register targets for new nodes/edges. New nodes spawn at their parent's
    /// current position (so they visibly "emerge" from it) when animating.
    private func seedMotionState(animated: Bool) {
        let t = Date.now.timeIntervalSinceReferenceDate
        for layout in engine.layouts {
            let target = CGPoint(x: layout.x, y: layout.y)
            if animPositions[layout.nodeID] == nil {
                if animated,
                   let node = nodeIndex[layout.nodeID],
                   let parentID = node.parentIDs.first,
                   let parentPos = animPositions[parentID] {
                    animPositions[layout.nodeID] = parentPos
                } else if animated,
                          let edge = engine.edges.first(where: { $0.to == layout.nodeID }),
                          let parentPos = animPositions[edge.from] {
                    animPositions[layout.nodeID] = parentPos
                } else {
                    animPositions[layout.nodeID] = target
                }
                nodeAppearTimes[layout.nodeID] = animated ? t : t - Self.appearDuration
            }
        }
        for edge in engine.edges {
            let key = "\(edge.from)->\(edge.to)"
            if edgeAppearTimes[key] == nil {
                edgeAppearTimes[key] = animated ? t : t - Self.edgeDrawDuration
            }
        }
    }

    /// One 30Hz frame: advance the clock, ease positions toward layout
    /// targets, and ease the camera when following.
    private func advanceMotion(to t: TimeInterval) {
        let animatingLayout = engine.layouts.contains { layout in
            guard let pos = animPositions[layout.nodeID] else { return false }
            return abs(pos.x - layout.x) > 0.5 || abs(pos.y - layout.y) > 0.5
        }
        let appearing = nodeAppearTimes.values.contains { t - $0 < Self.appearDuration }
        let drawingEdges = edgeAppearTimes.values.contains { t - $0 < Self.edgeDrawDuration }
        let needsFrame = runningCount > 0 || animatingLayout || appearing || drawingEdges

        guard needsFrame else { return }
        now = t

        // ── Exponential ease toward layout targets ──
        if animatingLayout {
            let k: CGFloat = 0.22
            for layout in engine.layouts {
                guard var pos = animPositions[layout.nodeID] else { continue }
                pos.x += (layout.x - pos.x) * k
                pos.y += (layout.y - pos.y) * k
                if abs(pos.x - layout.x) < 0.3 { pos.x = layout.x }
                if abs(pos.y - layout.y) < 0.3 { pos.y = layout.y }
                animPositions[layout.nodeID] = pos
            }
        }

        // ── Follow-cam: keep the newest node near the anchor line ──
        if autoFollow, isStreaming, canvasSize.height > 0,
           let newestID = engine.layouts.max(by: {
               (nodeAppearTimes[$0.nodeID] ?? 0) < (nodeAppearTimes[$1.nodeID] ?? 0)
           })?.nodeID,
           let pos = animPositions[newestID] {
            let targetPanY = canvasSize.height * Self.followAnchor - 80 - pos.y * zoom
            let targetPanX = -pos.x * zoom * 0.35   // gentle horizontal bias toward the active lane
            panOffset.height += (targetPanY - panOffset.height) * 0.08
            panOffset.width += (targetPanX - panOffset.width) * 0.08
        }
    }

    // MARK: - Graph Canvas

    @ViewBuilder
    private var graphCanvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let selectedID = selectedNodeID
                let pulse = 0.8 + 0.2 * sin(now * (2 * .pi / 1.5))
                let lineage = lineageIDs(for: selectedID)
                let pillMode = zoom < Self.semanticZoomThreshold

                // ── 0. Dot grid (screen space, camera-locked) ──
                drawDotGrid(context: context, size: size)

                context.translateBy(x: size.width / 2 + panOffset.width,
                                    y: 80 + panOffset.height)
                context.scaleBy(x: zoom, y: zoom)

                // ── 1. Lane bands + titles ──
                drawLanes(context: context, pillMode: pillMode)

                // ── 2. Edges ──
                for edge in engine.edges {
                    drawEdge(edge, context: context, lineage: lineage, selectedID: selectedID)
                }

                // ── 3. Flow particles on edges into running nodes ──
                for edge in engine.edges {
                    guard nodeIndex[edge.to]?.status == .running else { continue }
                    drawParticles(edge, context: context)
                }

                // ── 4. Running-node glow ──
                for layout in engine.layouts {
                    guard let node = nodeIndex[layout.nodeID],
                          node.status == .running,
                          let pos = animPositions[layout.nodeID] else { continue }
                    let glowR: CGFloat = node.isAgent ? 52 : 36
                    let glowColor = node.isAgent ? Theme.agentAccent : node.category.color
                    let rect = CGRect(
                        x: pos.x - glowR, y: pos.y - glowR,
                        width: glowR * 2, height: glowR * 2
                    )
                    let glow = GraphicsContext.Shading.radialGradient(
                        Gradient(colors: [
                            glowColor.opacity(0.25 * pulse),
                            glowColor.opacity(0.0),
                        ]),
                        center: pos,
                        startRadius: 0,
                        endRadius: glowR
                    )
                    context.fill(Path(ellipseIn: rect), with: glow)
                }

                // ── 5. Nodes ──
                for layout in engine.layouts {
                    guard let node = nodeIndex[layout.nodeID],
                          let pos = animPositions[layout.nodeID] else { continue }

                    let onLineage = lineage?.contains(node.id) ?? true
                    var nodeContext = context
                    if node.status == .running { nodeContext.opacity = pulse }
                    if !onLineage { nodeContext.opacity *= 0.22 }

                    // Appear animation: scale up + fade in.
                    let born = nodeAppearTimes[node.id] ?? now
                    let age = now - born
                    let appear = min(1, max(0, age / Self.appearDuration))
                    let appearScale = 0.6 + 0.4 * easeOutCubic(appear)
                    nodeContext.opacity *= appear

                    if pillMode {
                        drawPill(node: node, at: pos, context: nodeContext,
                                 scale: appearScale, isSelected: selectedID == node.id)
                    } else {
                        drawCard(node: node, layout: layout, at: pos,
                                 context: nodeContext, scale: appearScale,
                                 isSelected: selectedID == node.id,
                                 isHovered: hoveredNodeID == node.id)
                    }
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    // MARK: - Canvas Draw Helpers

    /// Faint dot lattice that pans/zooms with the camera for spatial feedback.
    private func drawDotGrid(context: GraphicsContext, size: CGSize) {
        let worldSpacing: CGFloat = 56
        var spacing = worldSpacing * zoom
        // Halve density when zoomed out so the grid never becomes noise.
        while spacing < 24 { spacing *= 2 }

        let originX = size.width / 2 + panOffset.width
        let originY = 80 + panOffset.height
        let startX = originX.truncatingRemainder(dividingBy: spacing)
        let startY = originY.truncatingRemainder(dividingBy: spacing)

        var dots = Path()
        var x = startX
        while x < size.width {
            var y = startY
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                y += spacing
            }
            x += spacing
        }
        context.fill(dots, with: .color(Theme.primary.opacity(0.05)))
    }

    /// Soft rounded bands behind each lane, plus a small title above.
    private func drawLanes(context: GraphicsContext, pillMode: Bool) {
        guard engine.lanes.count > 1 else { return }

        let bandWidth = ThoughtGraphLayoutEngine.nodeSize.width + 44
        let nodeH = ThoughtGraphLayoutEngine.nodeSize.height

        for lane in engine.lanes {
            let rect = CGRect(
                x: lane.x - bandWidth / 2,
                y: lane.minY - nodeH,
                width: bandWidth,
                height: (lane.maxY - lane.minY) + nodeH * 2
            )
            let band = Path(roundedRect: rect, cornerRadius: 18)
            let tint = lane.isAgent ? Theme.agentAccent : Theme.accent
            context.fill(band, with: .color(tint.opacity(lane.isAgent ? 0.05 : 0.035)))
            context.stroke(band, with: .color(tint.opacity(0.10)), lineWidth: 1)

            guard !pillMode else { continue }
            context.draw(
                Text(lane.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(tint.opacity(0.75)),
                at: CGPoint(x: lane.x, y: rect.minY - 10),
                anchor: .center
            )
        }
    }

    /// One edge with kind-based styling, lineage dimming, and draw-in trim.
    private func drawEdge(
        _ edge: ThoughtGraphEdge,
        context: GraphicsContext,
        lineage: Set<String>?,
        selectedID: String?
    ) {
        guard let path = animatedEdgePath(edge) else { return }

        let onLineage: Bool
        if let lineage {
            onLineage = lineage.contains(edge.from) && lineage.contains(edge.to)
        } else {
            onLineage = true
        }

        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
        switch edge.kind {
        case .main:
            color = Theme.accent
            width = 1.6
            dash = [6, 5]
        case .spawn:
            color = Theme.agentAccent
            width = 2.2
            dash = []
        case .loop:
            color = Theme.agentAccent
            width = 1.2
            dash = []
        }

        let opacity: CGFloat = onLineage ? (selectedID == nil ? 0.35 : 0.7) : 0.06

        // Draw-in: trim the path while the edge is young.
        let born = edgeAppearTimes["\(edge.from)->\(edge.to)"] ?? now
        let progress = min(1, max(0, (now - born) / Self.edgeDrawDuration))
        let drawn = progress < 1
            ? path.trimmedPath(from: 0, to: easeOutCubic(progress))
            : path

        context.stroke(
            drawn,
            with: .color(color.opacity(opacity)),
            style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash)
        )
    }

    /// Two dots flowing parent→child along a live edge.
    private func drawParticles(_ edge: ThoughtGraphEdge, context: GraphicsContext) {
        let color = edge.kind == .main ? Theme.accent : Theme.agentAccent
        // Stagger per-edge via a stable hash so parallel edges don't sync up.
        let phaseOffset = Double(abs(edge.to.hashValue % 997)) / 997.0
        for i in 0..<2 {
            let t = CGFloat(((now * 0.45) + phaseOffset + Double(i) * 0.5)
                .truncatingRemainder(dividingBy: 1))
            guard let pt = animatedEdgePoint(edge, t: t) else { continue }
            let r: CGFloat = 2.6 * (0.7 + 0.3 * sin(.pi * t))  // swell mid-flight
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
        }
    }

    /// Compact category dot for semantic zoom.
    private func drawPill(
        node: ThoughtGraphNode,
        at pos: CGPoint,
        context: GraphicsContext,
        scale: CGFloat,
        isSelected: Bool
    ) {
        let baseR: CGFloat = node.isAgent ? 13 : 9
        let r = baseR * scale
        let color = node.category.color
        let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)

        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))

        if isSelected {
            context.stroke(
                Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                with: .color(Theme.primary.opacity(0.9)),
                lineWidth: 1.5
            )
        }
        if node.status == .error {
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(.red),
                lineWidth: 2
            )
        }
    }

    /// Full node card via the ImageRenderer snapshot cache.
    private func drawCard(
        node: ThoughtGraphNode,
        layout: ThoughtGraphLayout,
        at pos: CGPoint,
        context: GraphicsContext,
        scale: CGFloat,
        isSelected: Bool,
        isHovered: Bool
    ) {
        let collapsedSteps = node.isAgent && collapsedAgentIDs.contains(node.agentID ?? "")
            ? stepCountByAgentID[node.agentID ?? ""] ?? 0
            : nil
        let key = node.cacheKey(
            isSelected: isSelected, hovered: isHovered, collapsedSteps: collapsedSteps
        )

        let image: Image
        if let cached = snapshotCache[key] {
            image = cached
        } else {
            let view = ThoughtGraphNodeView(
                node: node, layout: layout,
                isSelected: isSelected, isHovered: isHovered,
                collapsedStepCount: collapsedSteps
            )
            let renderer = ImageRenderer(
                content: view.frame(width: layout.width, height: layout.height)
            )
            renderer.scale = 2
            #if os(macOS)
            guard let nsImage = renderer.nsImage else { return }
            image = Image(nsImage: nsImage)
            #else
            guard let uiImage = renderer.uiImage else { return }
            image = Image(uiImage: uiImage)
            #endif
            snapshotCache[key] = image
        }

        let w = layout.width * scale
        let h = layout.height * scale
        context.draw(image, in: CGRect(x: pos.x - w / 2, y: pos.y - h / 2, width: w, height: h))

        // Completed check, top-right of the card.
        if node.status == .completed && scale > 0.95 {
            context.draw(
                Text(Image(systemName: "checkmark.circle.fill"))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.success.opacity(0.85)),
                at: CGPoint(x: pos.x + layout.width / 2 + 4, y: pos.y - layout.height / 2 - 4),
                anchor: .center
            )
        }
    }

    // MARK: - Edge Geometry (animated positions)

    /// Bezier control points computed from the *animated* node positions so
    /// edges track their nodes mid-transition.
    private func animatedEdgeGeometry(_ edge: ThoughtGraphEdge)
        -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
        guard let p = animPositions[edge.from], let c = animPositions[edge.to] else { return nil }
        let size = ThoughtGraphLayoutEngine.nodeSize

        let sameLane = abs(p.x - c.x) < 1
        let start: CGPoint
        let end: CGPoint
        if sameLane {
            start = CGPoint(x: p.x, y: p.y + size.height / 2)
            end = CGPoint(x: c.x, y: c.y - size.height / 2)
        } else {
            let dir: CGFloat = c.x > p.x ? 1 : -1
            start = CGPoint(x: p.x + dir * size.width / 2, y: p.y)
            end = CGPoint(x: c.x, y: c.y - size.height / 2)
        }

        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(hypot(dx, dy), 1)
        let bow: CGFloat = sameLane ? min(len * 0.12, 26) : min(len * 0.25, 60)
        let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)
        return (start, ctrl, end)
    }

    private func animatedEdgePath(_ edge: ThoughtGraphEdge) -> Path? {
        guard let g = animatedEdgeGeometry(edge) else { return nil }
        var path = Path()
        path.move(to: g.start)
        path.addQuadCurve(to: g.end, control: g.control)
        return path
    }

    private func animatedEdgePoint(_ edge: ThoughtGraphEdge, t: CGFloat) -> CGPoint? {
        guard let g = animatedEdgeGeometry(edge) else { return nil }
        let u = 1 - t
        let x = u * u * g.start.x + 2 * u * t * g.control.x + t * t * g.end.x
        let y = u * u * g.start.y + 2 * u * t * g.control.y + t * t * g.end.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Lineage

    /// IDs on the ancestor path from the selected node back to its lane root
    /// (following spawn edges across lanes). nil when nothing is selected.
    private func lineageIDs(for selectedID: String?) -> Set<String>? {
        guard let selectedID else { return nil }
        var parentByChild: [String: String] = [:]
        for edge in engine.edges {
            parentByChild[edge.to] = edge.from
        }
        var path: Set<String> = [selectedID]
        var cursor = selectedID
        while let parent = parentByChild[cursor], !path.contains(parent) {
            path.insert(parent)
            cursor = parent
        }
        return path
    }

    // MARK: - Easing

    private func easeOutCubic(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isStreaming
                  ? "arrow.triangle.2.circlepath"
                  : "square.stack.3d.up")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)

            Text(isStreaming ? "Waiting for agent..." : "No activity yet")
                .font(.headline)
                .foregroundStyle(Theme.secondary)

            if isStreaming {
                Text("Thoughts and tool calls will appear here as the agent works")
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
                    Text("\(runningCount) running")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                }

                if engine.lanes.count > 1 {
                    Text("\(engine.lanes.count - 1) subagents")
                        .font(.caption2)
                        .foregroundStyle(Theme.agentAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.agentAccent.opacity(0.12), in: Capsule())
                }

                if let usageSummary {
                    Text(usageSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surface, in: Capsule())
                        .help("Session token usage")
                }

                Spacer()
            }

            // Legend
            HStack(spacing: 12) {
                legendItem(icon: "arrow.triangle.2.circlepath", color: Theme.warning, label: "running")
                legendItem(icon: "checkmark.circle.fill", color: Theme.success, label: "completed")
                legendItem(icon: "xmark.circle.fill", color: Color.red, label: "error")
                legendItem(icon: "brain", color: Theme.agentAccent, label: "subagent")
                legendItem(icon: "bubble.left", color: Theme.graphReasoning, label: "thought")
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

    // MARK: - Follow Pill

    private var followPill: some View {
        Button {
            autoFollow = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .semibold))
                Text("Follow")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.warning, in: Capsule())
            .shadow(color: Theme.warning.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(16)
        .transition(.scale.combined(with: .opacity))
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
                autoFollow = true
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

    // MARK: - Reasoning Toggle

    private var reasoningToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                showReasoningBeats.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10, weight: .medium))
                Text("Thoughts")
                    .font(.caption2)
                if showReasoningBeats {
                    Circle()
                        .fill(Theme.graphReasoning)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(showReasoningBeats ? Theme.primary : Theme.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                showReasoningBeats
                    ? Theme.graphReasoning.opacity(0.18)
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
                    isSelected: false, isHovered: false,
                    collapsedStepCount: nil
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

            // ── Context / agent goal ──
            if let ctx = node.context {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.isAgent ? "Goal" : "Context")
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

            // ── Agent details ──
            if node.isAgent {
                agentDetailSections(node: node)
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

            Spacer()

            // ── Actions ──
            VStack(alignment: .leading, spacing: 8) {
                if node.isAgent, let agentID = node.agentID {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if collapsedAgentIDs.contains(agentID) {
                                collapsedAgentIDs.remove(agentID)
                            } else {
                                collapsedAgentIDs.insert(agentID)
                            }
                            invalidateSnapshots(for: node.id)
                        }
                    } label: {
                        let collapsed = collapsedAgentIDs.contains(agentID)
                        let steps = stepCountByAgentID[agentID] ?? 0
                        Label(
                            collapsed ? "Expand loop (\(steps) steps)" : "Collapse loop",
                            systemImage: collapsed
                                ? "chevron.down.circle" : "chevron.up.circle"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.agentAccent)
                }

                if let onJumpToTool, node.category != .reasoning, !node.isAgent, node.ownerAgentID == nil {
                    Button {
                        onJumpToTool(node.id)
                    } label: {
                        Label("Jump to tool in chat", systemImage: "arrow.turn.up.right")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .ignoresSafeArea(.container, edges: .vertical)
    }

    /// Subagent-specific detail sections: model, loop stats, live thinking.
    @ViewBuilder
    private func agentDetailSections(node: ThoughtGraphNode) -> some View {
        let loopSteps = stepCountByAgentID[node.agentID ?? ""] ?? 0

        VStack(alignment: .leading, spacing: 4) {
            Text("Agent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 12)

            HStack(spacing: 10) {
                if let model = node.modelName, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.agentAccent)
                        .lineLimit(1)
                }
                Label("\(loopSteps) steps", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
            }

            if node.costUSD != nil || node.tokenTotal != nil {
                HStack(spacing: 10) {
                    if let cost = node.costUSD {
                        Label(String(format: "$%.4f", cost), systemImage: "dollarsign.circle")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                    if let tokens = node.tokenTotal {
                        Label("\(tokens) tok", systemImage: "number.circle")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)

        if let thinking = node.agentThinking, !thinking.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Thinking")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    if node.status == .running {
                        Circle()
                            .fill(Theme.agentAccent)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.top, 12)

                ScrollViewReader { proxy in
                    ScrollView {
                        Text(thinking)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("thinking-tail")
                    }
                    .frame(maxHeight: 140)
                    .onAppear { proxy.scrollTo("thinking-tail", anchor: .bottom) }
                    .onChange(of: thinking) { _, _ in
                        proxy.scrollTo("thinking-tail", anchor: .bottom)
                    }
                }
                .padding(8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 14)
        }
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
        let pillMode = zoom < Self.semanticZoomThreshold

        for layout in engine.layouts {
            guard let pos = animPositions[layout.nodeID] else { continue }
            let sx = pos.x * zoom + canvasCenterX
            let sy = pos.y * zoom + canvasCenterY

            let rect: CGRect
            if pillMode {
                // Generous touch target around the dot.
                let r: CGFloat = 16
                rect = CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)
            } else {
                let sw = layout.width * zoom
                let sh = layout.height * zoom
                rect = CGRect(x: sx - sw / 2, y: sy - sh / 2, width: sw, height: sh)
            }

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
        let newZoom = max(0.25, min(4.0, oldZoom * factor))
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
                autoFollow = false
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
                        autoFollow = false
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
    func cacheKey(isSelected: Bool, hovered: Bool, collapsedSteps: Int?) -> String {
        "\(id)-sel\(isSelected)-hov\(hovered)-\(status.rawValue)-col\(collapsedSteps.map(String.init) ?? "n")"
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
        .frame(width: 900, height: 700)
        .preferredColorScheme(.dark)
    }

    @MainActor
    static func makeSampleNodes() -> [ThoughtGraphNode] {
        let t0 = Date(timeIntervalSinceNow: -60)
        func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

        let r1 = ThoughtGraphNode(
            id: "r1", name: "reasoning",
            context: "Locate the layout engine",
            summary: "Need to find where DAG layout happens before changing it.",
            isComplete: true, startedAt: at(0)
        )
        let n1 = ThoughtGraphNode(
            id: "t1", name: "search_files",
            context: "Searching for DAG layout code...",
            isComplete: true, durationSeconds: 0.82, startedAt: at(2)
        )
        let n2 = ThoughtGraphNode(
            id: "t2", name: "read_file",
            context: "Reading ThoughtGraphLayoutEngine.swift",
            summary: "320 lines, 12 KB",
            isComplete: true, durationSeconds: 0.34, startedAt: at(5)
        )
        let n3 = ThoughtGraphNode(
            id: "t3", name: "delegate_task",
            context: "Delegating reconnect audit",
            isComplete: false, startedAt: at(8)
        )
        let a1 = ThoughtGraphNode(
            id: "agent-s1", name: "agent",
            context: "Audit gateway reconnect handling for races",
            isComplete: false, startedAt: at(9),
            agentID: "s1", modelName: "claude-sonnet-5",
            agentThinking: "Scanning GatewayClient.receiveLoop for unguarded state transitions..."
        )
        let a1t1 = ThoughtGraphNode(
            id: "agent-s1-t1", name: "grep",
            context: "receiveLoop|reconnect",
            isComplete: true, startedAt: at(11), ownerAgentID: "s1"
        )
        let a1t2 = ThoughtGraphNode(
            id: "agent-s1-t2", name: "read_file",
            context: "GatewayClient.swift",
            isComplete: false, startedAt: at(14), ownerAgentID: "s1"
        )
        let n4 = ThoughtGraphNode(
            id: "t4", name: "write_file",
            context: "Creating ThoughtGraphView.swift...",
            isComplete: false, startedAt: at(16)
        )
        // Explicit spawn lineage for the preview
        var agent = a1
        agent.parentIDs = ["t3"]
        return [r1, n1, n2, n3, agent, a1t1, a1t2, n4]
    }
}
#endif
