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
                compactions: chatViewModel.currentTurnCompactions,
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

/// A compact, HIGH-LEVEL overview of the current turn — a small "chart filling
/// in" that sits inline in the chat so you can glance at what's happening
/// without breaking out to the full graph.
///
/// Deliberately NOT a miniature of the expanded flamechart: it drops the full
/// view's detail chrome — the elapsed-time ruler and "Ns" tick labels, the
/// per-reasoning-beat text gists, and the inline bar name labels. What's left
/// is the shape of the turn filling in over time: bars (x = start time, width =
/// duration, lanes stacked by actor) plus reasoning dots and compaction folds.
/// Tapping the strip opens the full session graph, where all that detail lives.
internal struct InlineTurnTimelineStrip: View {
    /// The current turn's composed nodes (tools + subagent lanes + reasoning),
    /// rebuilt by the caller as live events arrive.
    internal let nodes: [ThoughtGraphNode]
    /// Context-compaction folds for the live turn, drawn as full-height rules.
    internal var compactions: [CompactionMarker] = []
    /// Whether the turn is still streaming — drives the growing right edge and
    /// the live rescale so the whole turn keeps fitting the strip width.
    internal let isStreaming: Bool
    /// Tap handler — opens the full session graph.
    internal var onExpand: (() -> Void)?

    @StateObject private var engine = ThoughtGraphLayoutEngine()
    @State private var now: TimeInterval = Date.now.timeIntervalSinceReferenceDate
    @State private var relayoutTask: Task<Void, Never>?

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

    /// A bar is still growing only if the turn is streaming AND some non-
    /// reasoning node is running (started, not completed). When false the strip
    /// is static, so the growth timer stays idle — no per-frame work.
    private var hasGrowingBar: Bool {
        isStreaming && nodes.contains { $0.status == .running && $0.category != .reasoning }
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
        .onChange(of: nodes.count) { _, _ in debouncedRelayout() }
        // Advance "now" only while a bar is actually GROWING (a running,
        // non-reasoning node) — otherwise the strip is static and needs no
        // ticking. Plain assignment: the Canvas redraw is the animation;
        // wrapping a 4Hz state write in withAnimation piled up transactions on
        // the main thread and beachballed during streaming. 4Hz is plenty for
        // a bar that grows ~46pt/sec.
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { tick in
            guard hasGrowingBar else { return }
            now = tick.timeIntervalSinceReferenceDate
        }
        .help("Live timeline — tap to open the session graph")
    }

    private func relayout() {
        engine.layout(nodes: nodes, now: Date())
    }

    private func debouncedRelayout() {
        relayoutTask?.cancel()
        relayoutTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            relayout()
        }
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
                continue   // just the dot — the beat's gist lives in the full graph
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
            // No inline bar label here — the high-level strip shows the SHAPE of
            // the turn filling in; names/gists/timings live in the full graph.
        }

        // ── Compaction folds (over the bars) ──
        // A full-height rule wherever the agent compacted its context, mapped
        // by the same time→x scale as the bars so it lands between the right
        // steps. Mirrors the full graph; the strip is where the user WATCHES a
        // compaction happen, so it must show up live.
        drawCompactionFolds(context: context, size: size, scale: scale)
    }

    /// Full-height compaction rules for the strip, positioned by the same
    /// time→x scale as the bars (`world x=0` sits at `leftGutter`, mapped from
    /// wall-clock via `engine.timeOrigin`). A `/compress` is solid; an
    /// automatic fold is dashed and quieter. Skipped when the turn has no real
    /// time origin (nothing to anchor to) — never faked.
    private func drawCompactionFolds(context: GraphicsContext, size: CGSize, scale: CGFloat) {
        guard !compactions.isEmpty, let t0 = engine.timeOrigin else { return }
        func sx(_ worldX: CGFloat) -> CGFloat { Self.sidePad + worldX * scale }
        let ruleBottom = size.height - Self.bottomPad

        for marker in compactions {
            let worldX = ThoughtGraphLayoutEngine.leftGutter
                + marker.at.timeIntervalSince(t0) * ThoughtGraphLayoutEngine.pixelsPerSecond
            let x = sx(worldX)
            guard x >= Self.sidePad, x <= size.width - Self.sidePad else { continue }

            var rule = Path()
            rule.move(to: CGPoint(x: x, y: Self.topPad))
            rule.addLine(to: CGPoint(x: x, y: ruleBottom))
            let solid = marker.trigger == .manual
            context.stroke(
                rule,
                with: .color(Theme.graphCompaction.opacity(solid ? 0.75 : 0.55)),
                style: StrokeStyle(
                    lineWidth: solid ? 1.4 : 1,
                    lineCap: .round,
                    dash: solid ? [] : [4, 3]
                )
            )
            // A tiny glyph cap at the top marks it as a compaction, not a tick.
            context.draw(
                Text("⟳")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Theme.graphCompaction),
                at: CGPoint(x: x, y: Self.topPad + 4),
                anchor: .center
            )
        }
    }
}
