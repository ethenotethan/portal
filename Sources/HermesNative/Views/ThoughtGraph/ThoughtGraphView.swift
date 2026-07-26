// swiftlint:disable file_length type_body_length
// Legacy giant — split tracked as debt; do not add to this file.
import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - ThoughtGraphView

/// Interactive time-plot ("flamechart") of the live agent react loop.
///
/// The graph reads as a timeline: horizontal position is WHEN a step happened,
/// bar width is HOW LONG it took, and each actor (the main loop + every spawned
/// subagent) owns its own horizontal lane, stacked top→down by spawn order.
///
/// ## Architecture
/// - **Layout**: `ThoughtGraphLayoutEngine` (time on x, lanes on y, width ∝
///   duration). See that file for the scale.
/// - **Rendering**: bars are drawn directly in a SwiftUI `Canvas` (rounded
///   rects + inline labels) — no per-node image snapshots. Reasoning beats are
///   durationless diamonds. Running bars grow rightward to "now" each frame.
/// - **Motion**: a 30 Hz tick advances the clock so running bars extend and
///   pulse; new bars fade in; the follow-cam tails the newest activity
///   horizontally while streaming until the user pans.
/// - **Camera**: pan + zoom; macOS `GraphMouseInterceptor`, iOS drag + pinch.
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

    /// Set once we've framed the graph to fit, so we don't re-fit (and fight
    /// the user's manual zoom/pan) on every layout pass. Reset when the graph
    /// identity changes (a different turn/session loads).
    @State private var hasFitted: Bool = false

    /// True once the user manually zooms/pans — suppresses auto-refit so we
    /// never yank the camera out from under them.
    @State private var hasUserAdjustedCamera: Bool = false

    // ── Motion state (advanced by the 30Hz tick) ──
    @State private var nodeAppearTimes: [String: TimeInterval] = [:]
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

    // MARK: - Constants

    private static let appearDuration: TimeInterval = 0.3
    /// Screen-space origin of world (0,0): room for the header + time axis on
    /// top, and lane titles on the left.
    private static let topMargin: CGFloat = 96
    private static let leftMargin: CGFloat = 118
    /// Below this zoom, bar labels are dropped (bars stay, just quieter).
    private static let labelZoomThreshold: CGFloat = 0.5
    /// While following, keep the newest activity this far across the viewport.
    private static let followAnchorX: CGFloat = 0.72

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
        GeometryReader { _ in
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
                            hasUserAdjustedCamera = true
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
            // Double-tap reframes the whole graph — the quick global overview.
            hasUserAdjustedCamera = false
            fitToView(animated: true)
        }
        #endif

        .onAppear {
            engine.layout(nodes: visibleNodes, now: Date())
            seedAppearTimes(animated: false)
            fitIfNeeded(animated: false)
        }
        .onChange(of: layoutKey) { _, _ in
            engine.layout(nodes: visibleNodes, now: Date())
            seedAppearTimes(animated: true)
            // A filter toggle (collapse/reasoning) changed the graph — reframe
            // it unless the user has taken manual control of the camera.
            if !hasUserAdjustedCamera { hasFitted = false }
            fitIfNeeded(animated: true)
        }

        // ── 30Hz motion tick: grow running bars, pulse, follow-cam ──
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { tick in
            advanceMotion(to: tick.timeIntervalSinceReferenceDate)
        }
    }

    // MARK: - Motion

    /// Register appear times for newly-seen nodes so they fade in.
    private func seedAppearTimes(animated: Bool) {
        let t = Date.now.timeIntervalSinceReferenceDate
        for layout in engine.layouts where nodeAppearTimes[layout.nodeID] == nil {
            nodeAppearTimes[layout.nodeID] = animated ? t : t - Self.appearDuration
        }
    }

    /// One 30Hz frame: advance the clock (running bars grow + pulse) and ease
    /// the follow-cam horizontally toward the newest activity.
    private func advanceMotion(to t: TimeInterval) {
        let appearing = nodeAppearTimes.values.contains { t - $0 < Self.appearDuration }
        // Running bars are recomputed from `now` at draw time, so we only need
        // frames while something is live or animating in.
        let needsFrame = runningCount > 0 || appearing
        guard needsFrame else { return }
        now = t

        guard autoFollow, isStreaming, canvasSize.width > 0 else { return }
        // Keep the rightmost live edge near the anchor line.
        let nowDate = Date()
        let maxRight = engine.layouts.map { layout -> Double in
            guard let node = nodeIndex[layout.nodeID] else { return layout.x + layout.width }
            return layout.x + engine.liveWidth(for: node, laidOut: layout.width, now: nowDate)
        }.max() ?? 0
        let targetPanX = canvasSize.width * Self.followAnchorX - Self.leftMargin - maxRight * zoom
        panOffset.width += (targetPanX - panOffset.width) * 0.08
    }

    // MARK: - Graph Canvas

    @ViewBuilder
    private var graphCanvas: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let selectedID = selectedNodeID
                let pulse = 0.7 + 0.3 * sin(now * (2 * .pi / 1.2))
                let lineage = lineageIDs(for: selectedID)
                let showLabels = zoom >= Self.labelZoomThreshold
                let nowDate = Date()

                // ── 0. Time axis (screen space, top) ──
                drawTimeAxis(context: context, size: size)

                context.translateBy(x: Self.leftMargin + panOffset.width,
                                    y: Self.topMargin + panOffset.height)
                context.scaleBy(x: zoom, y: zoom)

                // ── 1. Lane bands + titles ──
                drawLanes(context: context, showLabels: showLabels)

                // ── 2. Spawn edges ──
                for edge in engine.edges {
                    drawSpawnEdge(edge, context: context, lineage: lineage, selectedID: selectedID)
                }

                // ── 3. Bars ──
                for layout in engine.layouts {
                    guard let node = nodeIndex[layout.nodeID] else { continue }
                    drawBar(
                        node: node, layout: layout, context: context,
                        pulse: pulse, showLabel: showLabels,
                        lineage: lineage, selectedID: selectedID, now: nowDate
                    )
                }
            }
            .onAppear { canvasSize = geo.size; fitIfNeeded(animated: false) }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                fitIfNeeded(animated: false)
            }
        }
    }

    // MARK: - Canvas Draw Helpers

    /// Elapsed-time ruler across the top: faint vertical gridlines + "Ns"
    /// labels at nice intervals, positioned by the same time→x scale as bars.
    private func drawTimeAxis(context: GraphicsContext, size: CGSize) {
        let pps = ThoughtGraphLayoutEngine.pixelsPerSecond * zoom
        guard pps > 0 else { return }

        // Pick a tick interval that keeps labels ~70pt apart on screen.
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let interval = candidates.first { $0 * pps >= 70 } ?? 600

        let originX = Self.leftMargin + panOffset.width
            + ThoughtGraphLayoutEngine.leftGutter * zoom
        var second = 0.0
        var gridlines = Path()
        while true {
            let x = originX + second * pps
            if x > size.width { break }
            if x >= Self.leftMargin - 1 {
                gridlines.move(to: CGPoint(x: x, y: Self.topMargin - 8))
                gridlines.addLine(to: CGPoint(x: x, y: size.height))
                context.draw(
                    Text(tickLabel(second))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.tertiary),
                    at: CGPoint(x: x + 3, y: Self.topMargin - 14),
                    anchor: .leading
                )
            }
            second += interval
        }
        context.stroke(gridlines, with: .color(Theme.primary.opacity(0.05)), lineWidth: 1)
    }

    private func tickLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }

    /// Full-width horizontal band behind each lane, tinted by actor, with the
    /// lane title pinned at the left.
    private func drawLanes(context: GraphicsContext, showLabels: Bool) {
        let laneH = ThoughtGraphLayoutEngine.laneHeight
        let totalWidth = engine.totalSize.width

        for lane in engine.lanes {
            let rect = CGRect(
                x: -ThoughtGraphLayoutEngine.leftGutter,
                y: lane.y - laneH / 2,
                width: totalWidth,
                height: laneH
            )
            let band = Path(roundedRect: rect, cornerRadius: 10)
            let tint = lane.isAgent ? Theme.agentAccent : Theme.accent
            context.fill(band, with: .color(tint.opacity(lane.isAgent ? 0.05 : 0.035)))

            guard showLabels else { continue }
            context.draw(
                Text(lane.title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(tint.opacity(0.8)),
                at: CGPoint(x: rect.minX + 6, y: lane.y - laneH / 2 + 9),
                anchor: .leading
            )
        }
    }

    /// A spawn edge: the delegating tool bar's right edge arcing down into the
    /// subagent lane's first bar.
    private func drawSpawnEdge(
        _ edge: ThoughtGraphEdge,
        context: GraphicsContext,
        lineage: Set<String>?,
        selectedID: String?
    ) {
        guard let pts = engine.edgeControlPoints(from: edge.from, to: edge.to) else { return }
        var path = Path()
        path.move(to: pts.start)
        path.addQuadCurve(to: pts.end, control: pts.control)

        let onLineage: Bool
        if let lineage {
            onLineage = lineage.contains(edge.from) && lineage.contains(edge.to)
        } else {
            onLineage = true
        }
        let opacity: CGFloat = onLineage ? (selectedID == nil ? 0.5 : 0.8) : 0.08
        context.stroke(
            path,
            with: .color(Theme.agentAccent.opacity(opacity)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
    }

    /// One node: a duration bar (tool/agent) or a diamond marker (reasoning).
    private func drawBar(
        node: ThoughtGraphNode,
        layout: ThoughtGraphLayout,
        context: GraphicsContext,
        pulse: Double,
        showLabel: Bool,
        lineage: Set<String>?,
        selectedID: String?,
        now: Date
    ) {
        let onLineage = lineage?.contains(node.id) ?? true
        let born = nodeAppearTimes[node.id] ?? self.now
        let appear = min(1, max(0, (self.now - born) / Self.appearDuration))

        var ctx = context
        ctx.opacity = (onLineage ? 1 : 0.2) * appear
        if node.status == .running { ctx.opacity *= pulse }

        let isSelected = selectedID == node.id
        let isHovered = hoveredNodeID == node.id
        let color = node.category.color

        // Reasoning beats: durationless diamond markers.
        if node.category == .reasoning {
            let s = ThoughtGraphLayoutEngine.markerSize
            let c = CGPoint(x: layout.x + s / 2, y: layout.y)
            var diamond = Path()
            diamond.move(to: CGPoint(x: c.x, y: c.y - s / 2))
            diamond.addLine(to: CGPoint(x: c.x + s / 2, y: c.y))
            diamond.addLine(to: CGPoint(x: c.x, y: c.y + s / 2))
            diamond.addLine(to: CGPoint(x: c.x - s / 2, y: c.y))
            diamond.closeSubpath()
            ctx.fill(diamond, with: .color(color.opacity(0.9)))
            if isSelected || isHovered {
                ctx.stroke(diamond, with: .color(Theme.primary.opacity(0.9)), lineWidth: 1.5)
            }
            return
        }

        let width = engine.liveWidth(for: node, laidOut: layout.width, now: now)
        let h = ThoughtGraphLayoutEngine.barHeight
        let rect = CGRect(x: layout.x, y: layout.y - h / 2, width: width, height: h)
        let shape = Path(roundedRect: rect, cornerRadius: 6)

        // Fill: agents get a stronger tint; running bars a subtle sheen.
        ctx.fill(shape, with: .color(color.opacity(node.isAgent ? 0.9 : 0.72)))
        if node.isAgent {
            ctx.stroke(shape, with: .color(Theme.agentAccent), lineWidth: 1)
        }

        // Status affordances.
        if node.status == .error {
            ctx.stroke(shape, with: .color(.red), lineWidth: 2)
        }
        if isSelected {
            ctx.stroke(
                Path(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), cornerRadius: 8),
                with: .color(Theme.primary.opacity(0.9)), lineWidth: 1.5
            )
        } else if isHovered {
            ctx.stroke(shape, with: .color(Theme.primary.opacity(0.5)), lineWidth: 1)
        }

        // Inline label, clipped to the bar when there's room.
        guard showLabel, width >= 34 else { return }
        let label = node.isAgent ? "◆ \(node.name)" : node.name
        var labelCtx = ctx
        labelCtx.clip(to: shape)
        labelCtx.draw(
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.95)),
            at: CGPoint(x: rect.minX + 6, y: rect.midY),
            anchor: .leading
        )
    }

    // MARK: - Lineage

    /// IDs on the ancestor path from the selected node back through spawn
    /// edges. nil when nothing is selected.
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isStreaming
                  ? "arrow.triangle.2.circlepath"
                  : "chart.bar.xaxis")
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
                legendItem(icon: "diamond.fill", color: Theme.graphReasoning, label: "thought")
                Text("← width = duration →")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
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
                Image(systemName: "arrow.right.to.line")
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
                // Fit the whole graph back into view — the global overview.
                hasUserAdjustedCamera = false
                fitToView(animated: true)
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Fit graph to view")
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
                Image(systemName: "diamond")
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

    /// Convert a point in view-space to a node ID, if any. Bars are
    /// left-anchored; markers are centered diamonds.
    private func hitTest(point: CGPoint) -> String? {
        let originX = Self.leftMargin + panOffset.width
        let originY = Self.topMargin + panOffset.height
        let nowDate = Date()

        // Reverse order so topmost-drawn (later) bars win overlaps.
        for layout in engine.layouts.reversed() {
            guard let node = nodeIndex[layout.nodeID] else { continue }
            let rect: CGRect
            if node.category == .reasoning {
                let s = ThoughtGraphLayoutEngine.markerSize * zoom
                let cx = (layout.x + ThoughtGraphLayoutEngine.markerSize / 2) * zoom + originX
                let cy = layout.y * zoom + originY
                rect = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
            } else {
                let w = engine.liveWidth(for: node, laidOut: layout.width, now: nowDate)
                let h = ThoughtGraphLayoutEngine.barHeight
                let sx = layout.x * zoom + originX
                let sy = (layout.y - h / 2) * zoom + originY
                // Pad narrow bars for a usable touch target.
                let drawnW = max(w * zoom, 10)
                rect = CGRect(x: sx, y: sy, width: drawnW, height: h * zoom)
            }
            if rect.insetBy(dx: -3, dy: -3).contains(point) {
                return layout.nodeID
            }
        }
        return nil
    }

    // MARK: - Zoom

    /// Frame the ENTIRE graph in the viewport — the global overview. Computes
    /// the zoom that fits the laid-out bounds (clamped to the zoom range) and
    /// centers it, so the graph opens whole instead of anchored top-left and
    /// running off-screen. Disengages follow so the fit isn't immediately
    /// yanked away by the camera.
    private func fitToView(animated: Bool) {
        let world = engine.totalSize
        guard world.width > 1, world.height > 1,
              canvasSize.width > 1, canvasSize.height > 1 else { return }

        // Available plot area inside the chrome margins, with a little padding.
        let padding: CGFloat = 24
        let availW = max(1, canvasSize.width - Self.leftMargin - padding)
        let availH = max(1, canvasSize.height - Self.topMargin - padding)
        let fit = min(availW / world.width, availH / world.height)
        let targetZoom = max(0.25, min(4.0, fit))

        // Center the scaled world in the available area (world origin sits at
        // leftMargin/topMargin, then panOffset shifts from there).
        let scaledW = world.width * targetZoom
        let scaledH = world.height * targetZoom
        let targetPan = CGSize(
            width: max(0, (availW - scaledW) / 2),
            height: max(0, (availH - scaledH) / 2)
        )

        autoFollow = false
        if animated {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                zoom = targetZoom
                panOffset = targetPan
            }
        } else {
            zoom = targetZoom
            panOffset = targetPan
        }
    }

    /// Fit exactly once per graph, when the canvas size is known. Onappear can
    /// fire before GeometryReader reports a size, so `canvasSize` becoming
    /// valid also calls this.
    private func fitIfNeeded(animated: Bool) {
        guard !hasFitted, canvasSize.width > 1, engine.totalSize.width > 1 else { return }
        hasFitted = true
        fitToView(animated: animated)
    }

    private func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        hasUserAdjustedCamera = true
        let oldZoom = zoom
        let newZoom = max(0.25, min(4.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        // Keep the point under the cursor stable across the zoom.
        panOffset.width += (point.x - Self.leftMargin - panOffset.width)
            * (1 - newZoom / oldZoom)
        panOffset.height += (point.y - Self.topMargin - panOffset.height)
            * (1 - newZoom / oldZoom)
        zoom = newZoom
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
                hasUserAdjustedCamera = true
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
                        hasUserAdjustedCamera = true
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
        engine.layout(nodes: sampleNodes, now: Date())

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
            isComplete: true, durationSeconds: 1.1, startedAt: at(8)
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
            isComplete: true, durationSeconds: 0.5, startedAt: at(11), ownerAgentID: "s1"
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
