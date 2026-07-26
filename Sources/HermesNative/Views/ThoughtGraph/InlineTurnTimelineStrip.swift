import SwiftUI

/// Live wrapper: observes the two per-turn graph integrators directly (like
/// the full-graph sheet does), composes the current turn's nodes as events
/// arrive, and feeds the compact strip. Observing here — not in ChatView,
/// which only watches chatViewModel — is what makes the strip rebuild live as
/// subagent/reasoning publishes land. Renders nothing until there's activity.
internal struct InlineTurnTimelineLive: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    @ObservedObject internal var subagentGraph: SubagentGraphIntegrator
    @ObservedObject internal var reasoningGraph: ReasoningGraphIntegrator
    internal var onExpand: (() -> Void)?

    internal var body: some View {
        let live = nodes
        if !live.isEmpty {
            InlineTurnTimelineStrip(
                nodes: live,
                isStreaming: chatViewModel.isStreaming,
                onExpand: onExpand
            )
            .padding(.trailing, 16)
            .padding(.vertical, 2)
        }
    }

    private var nodes: [ThoughtGraphNode] {
        ThoughtGraphLayoutEngine.composeTimeline(
            tools: Array(chatViewModel.activeToolCalls.values).sorted { $0.id < $1.id },
            agentNodes: subagentGraph.agentNodes,
            reasoningNodes: reasoningGraph.reasoningNodes
        )
    }
}

/// A compact live flamechart of the CURRENT turn, meant to sit inline in the
/// chat beside the streaming tool trace — the timeline fills in as tools run
/// and subagents take turns, without breaking out to the full-screen graph.
///
/// It shares the time-plot geometry of `ThoughtGraphView` (x = start time,
/// width = duration, lanes stacked by actor) but strips all the full-screen
/// chrome: no header, no zoom/follow controls, no detail popover, no
/// interception layer. Fixed short height; horizontal scroll auto-pinned to
/// the live right edge while streaming so new bars stay in view. Tapping the
/// strip opens the full session graph.
internal struct InlineTurnTimelineStrip: View {
    /// The current turn's composed nodes (tools + subagent lanes + reasoning),
    /// rebuilt by the caller as live events arrive.
    internal let nodes: [ThoughtGraphNode]
    /// Whether the turn is still streaming — drives the growing right edge and
    /// the live rescale so the whole turn keeps fitting the strip width.
    internal let isStreaming: Bool
    /// Tap handler — opens the full session graph.
    internal var onExpand: (() -> Void)?

    @StateObject private var engine = ThoughtGraphLayoutEngine()
    @State private var now: TimeInterval = Date.now.timeIntervalSinceReferenceDate

    private static let topPad: CGFloat = 6
    private static let bottomPad: CGFloat = 6
    private static let sidePad: CGFloat = 8
    /// Max drawable world-rows shown inline before the strip caps its height
    /// (deeper packing/lanes clip; the full graph shows everything).
    private static let maxStripWorldHeight: CGFloat = 132

    /// Strip drawable height tracks the packed world height (parallel bars +
    /// subagent lanes make it taller), capped so it never dominates the chat.
    private var drawableHeight: CGFloat {
        min(max(CGFloat(engine.totalSize.height), 26), Self.maxStripWorldHeight)
    }

    private var contentHeight: CGFloat {
        Self.topPad + Self.bottomPad + drawableHeight
    }

    /// World width of the laid-out graph (before fitting).
    private var worldWidth: CGFloat {
        max(engine.totalSize.width, 1)
    }

    internal var body: some View {
        // Fit-to-width: the whole turn always fits the strip. As time passes
        // the world grows, so the fit scale shrinks and bars smoothly rescale
        // in place — the timeline compresses rather than scrolling off-screen.
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .frame(height: contentHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { expandHint }
        .contentShape(Rectangle())
        .onTapGesture { onExpand?() }
        .onAppear { relayout() }
        .onChange(of: nodes.count) { _, _ in relayout() }
        // Advance "now" while streaming so running bars grow and the fit
        // rescales; animate the change so bars glide rather than jump.
        .onReceive(Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()) { tick in
            guard isStreaming else { return }
            withAnimation(.linear(duration: 1.0 / 12.0)) {
                now = tick.timeIntervalSinceReferenceDate
            }
        }
        .help("Live timeline — tap to open the session graph")
    }

    private func relayout() {
        engine.layout(nodes: nodes, now: Date())
    }

    /// Scale mapping world-x → the strip's available width. Recomputed each
    /// draw against the live world width so the turn stays fully framed.
    private func fitScale(for size: CGSize) -> CGFloat {
        let avail = max(1, size.width - Self.sidePad * 2)
        // For a running turn, extend the world to "now" so the fit accounts
        // for the growing bar and doesn't clip the live edge.
        let liveWorld = liveWorldWidth()
        return min(1, avail / liveWorld)
    }

    /// World width including any still-running bar grown to `now`.
    private func liveWorldWidth() -> CGFloat {
        let nowDate = Date()
        let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var maxRight = engine.totalSize.width
        for layout in engine.layouts {
            guard let node = nodeByID[layout.nodeID] else { continue }
            let w = engine.liveWidth(for: node, laidOut: layout.width, now: nowDate)
            maxRight = max(maxRight, layout.x + w + ThoughtGraphLayoutEngine.leftGutter)
        }
        return max(maxRight, 1)
    }

    private var expandHint: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8))
            .foregroundStyle(Theme.tertiary)
            .padding(4)
    }

    // MARK: - Draw

    private func draw(context: GraphicsContext, size: CGSize) {
        let nowDate = Date()
        let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let scale = fitScale(for: size)
        // Map world-x into fitted screen-x, and world-y proportionally into the
        // capped strip band so packed sub-rows (parallel bars) keep their
        // relative stacking instead of collapsing onto one line.
        func sx(_ worldX: CGFloat) -> CGFloat { Self.sidePad + worldX * scale }
        let worldH = max(CGFloat(engine.totalSize.height), 1)
        let yScale = min(1, drawableHeight / worldH)
        func sy(_ worldY: CGFloat) -> CGFloat { Self.topPad + worldY * yScale }

        for layout in engine.layouts {
            guard let node = nodeByID[layout.nodeID] else { continue }
            let cy = sy(CGFloat(layout.y))
            let color = node.category.color

            if node.category == .reasoning {
                let s: CGFloat = 8
                let cx = sx(layout.x + ThoughtGraphLayoutEngine.markerSize / 2)
                var diamond = Path()
                diamond.move(to: CGPoint(x: cx, y: cy - s / 2))
                diamond.addLine(to: CGPoint(x: cx + s / 2, y: cy))
                diamond.addLine(to: CGPoint(x: cx, y: cy + s / 2))
                diamond.addLine(to: CGPoint(x: cx - s / 2, y: cy))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(color.opacity(0.9)))
                continue
            }

            let worldWidth = engine.liveWidth(for: node, laidOut: layout.width, now: nowDate)
            // Scale bar thickness with the sub-row pitch so stacked bars don't touch.
            let barH: CGFloat = min(14, ThoughtGraphLayoutEngine.subRowPitch * yScale * 0.7)
            let x = sx(layout.x)
            let w = max(2, worldWidth * scale)   // floor so a bar never vanishes when fitted
            let rect = CGRect(x: x, y: cy - barH / 2, width: w, height: barH)
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            var ctx = context
            if node.status == .running {
                let pulse = 0.6 + 0.4 * sin(now * (2 * .pi / 1.0))
                ctx.opacity = pulse
            }
            ctx.fill(shape, with: .color(color.opacity(node.isAgent ? 0.9 : 0.7)))
            if node.isAgent {
                ctx.stroke(shape, with: .color(Theme.agentAccent), lineWidth: 0.8)
            }
            if node.status == .error {
                ctx.stroke(shape, with: .color(.red), lineWidth: 1.2)
            }

            // Inline label only when the fitted bar has room.
            if w >= 30 {
                var labelCtx = ctx
                labelCtx.clip(to: shape)
                labelCtx.draw(
                    Text(node.name)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.95)),
                    at: CGPoint(x: rect.minX + 4, y: rect.midY),
                    anchor: .leading
                )
            }
        }
    }
}
