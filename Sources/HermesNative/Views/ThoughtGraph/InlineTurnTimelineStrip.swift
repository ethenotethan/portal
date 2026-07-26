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
    /// the auto-scroll-to-now behavior.
    internal let isStreaming: Bool
    /// Tap handler — opens the full session graph.
    internal var onExpand: (() -> Void)?

    @StateObject private var engine = ThoughtGraphLayoutEngine()
    @State private var now: TimeInterval = Date.now.timeIntervalSinceReferenceDate

    /// One lane tall + a couple more if subagents appear, capped so the strip
    /// never dominates the transcript.
    private static let laneStripHeight: CGFloat = 26
    private static let maxLanes = 4
    private static let topPad: CGFloat = 6
    private static let bottomPad: CGFloat = 6

    private var laneCount: Int { max(1, min(engine.lanes.count, Self.maxLanes)) }

    private var contentHeight: CGFloat {
        Self.topPad + Self.bottomPad + CGFloat(laneCount) * Self.laneStripHeight
    }

    /// World width of the laid-out graph (for the scroll content).
    private var worldWidth: CGFloat {
        max(engine.totalSize.width, 1)
    }

    internal var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                Canvas { context, size in
                    draw(context: context, size: size)
                }
                .frame(width: worldWidth, height: contentHeight)
                // Anchor at the far right so auto-scroll-to-now works.
                .overlay(alignment: .trailing) {
                    Color.clear.frame(width: 1).id("live-edge")
                }
            }
            .onChange(of: nodes.count) { _, _ in
                relayout()
                if isStreaming { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("live-edge", anchor: .trailing) } }
            }
        }
        .frame(height: contentHeight)
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { expandHint }
        .contentShape(Rectangle())
        .onTapGesture { onExpand?() }
        .onAppear { relayout() }
        // Grow running bars + advance "now" while streaming.
        .onReceive(Timer.publish(every: 1.0 / 12.0, on: .main, in: .common).autoconnect()) { tick in
            guard isStreaming else { return }
            now = tick.timeIntervalSinceReferenceDate
        }
        .help("Live timeline — tap to open the session graph")
    }

    private func relayout() {
        engine.layout(nodes: nodes, now: Date())
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
        // Scale the engine's world-y (laneHeight pitch) down to the strip pitch.
        let laneScale = Self.laneStripHeight / ThoughtGraphLayoutEngine.laneHeight

        for layout in engine.layouts {
            guard let node = nodeByID[layout.nodeID] else { continue }
            let laneIndex = Int((layout.y / ThoughtGraphLayoutEngine.laneHeight).rounded())
            guard laneIndex < Self.maxLanes else { continue }   // clip deep lanes
            let cy = Self.topPad + (CGFloat(laneIndex) + 0.5) * Self.laneStripHeight
            let color = node.category.color

            if node.category == .reasoning {
                let s: CGFloat = 8
                let cx = layout.x + s / 2
                var diamond = Path()
                diamond.move(to: CGPoint(x: cx, y: cy - s / 2))
                diamond.addLine(to: CGPoint(x: cx + s / 2, y: cy))
                diamond.addLine(to: CGPoint(x: cx, y: cy + s / 2))
                diamond.addLine(to: CGPoint(x: cx - s / 2, y: cy))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(color.opacity(0.9)))
                continue
            }

            let width = engine.liveWidth(for: node, laidOut: layout.width, now: nowDate)
            let barH: CGFloat = 14
            let rect = CGRect(x: layout.x, y: cy - barH / 2, width: width, height: barH)
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

            // Inline label only when the bar has room.
            if width >= 30 {
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
