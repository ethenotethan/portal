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
    /// A thin ruler band under the bars for elapsed-time tick labels ("0s",
    /// "10s", …), so the strip reads as a time plot — you can see WHEN each bar
    /// started and the idle lapses between them, not just their order.
    private static let axisBandHeight: CGFloat = 13
    /// Max drawable world-rows shown inline before the strip caps its height
    /// (deeper packing/lanes clip; the full graph shows everything).
    private static let maxStripWorldHeight: CGFloat = 132

    /// Strip drawable height tracks the packed world height (parallel bars +
    /// subagent lanes make it taller), capped so it never dominates the chat.
    private var drawableHeight: CGFloat {
        min(max(CGFloat(engine.totalSize.height), 26), Self.maxStripWorldHeight)
    }

    private var contentHeight: CGFloat {
        Self.topPad + Self.bottomPad + drawableHeight + Self.axisBandHeight
    }

    /// A bar is still growing only if the turn is streaming AND some non-
    /// reasoning node is running (started, not completed). When false the strip
    /// is static, so the growth timer stays idle — no per-frame work.
    private var hasGrowingBar: Bool {
        isStreaming && nodes.contains { $0.status == .running && $0.category != .reasoning }
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

    /// Elapsed-time ruler for the strip: vertical gridlines at "nice" second
    /// intervals across the plot, with an "Ns" label in the bottom band under
    /// each line. Uses the same time→x scale as the bars (world x=0 sits at
    /// `leftGutter`), and picks the interval so labels stay ~56pt apart at the
    /// current fit — the whole point the user asked for: seeing the lapse
    /// between tool calls, not just their order.
    private func drawTimeAxis(context: GraphicsContext, size: CGSize, scale: CGFloat) {
        let pps = ThoughtGraphLayoutEngine.pixelsPerSecond * scale   // screen px per second
        guard pps > 0.5 else { return }   // too compressed to label — skip quietly

        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let interval = candidates.first { $0 * pps >= 56 } ?? 600

        // world x=0 (t0) → screen. leftGutter is the pad before the first bar.
        let originX = Self.sidePad + ThoughtGraphLayoutEngine.leftGutter * scale
        let axisTop = size.height - Self.axisBandHeight

        var gridlines = Path()
        var second = 0.0
        while true {
            let x = originX + second * pps
            if x > size.width - Self.sidePad { break }
            gridlines.move(to: CGPoint(x: x, y: Self.topPad))
            gridlines.addLine(to: CGPoint(x: x, y: axisTop))
            context.draw(
                Text(tickLabel(second))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Theme.tertiary),
                at: CGPoint(x: x + 2, y: axisTop + Self.axisBandHeight / 2),
                anchor: .leading
            )
            second += interval
        }
        context.stroke(gridlines, with: .color(Theme.primary.opacity(0.06)), lineWidth: 1)
    }

    private func tickLabel(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }

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

        // Time ruler behind the bars: faint gridlines + elapsed-second labels
        // so the lapse between bars is legible, not just their order.
        drawTimeAxis(context: context, size: size, scale: scale)

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
                continue   // label drawn in the second pass below
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

        // ── Compaction folds (over the bars) ──
        // A full-height rule wherever the agent compacted its context, mapped
        // by the same time→x scale as the bars so it lands between the right
        // steps. Mirrors the full graph; the strip is where the user WATCHES a
        // compaction happen, so it must show up live.
        drawCompactionFolds(context: context, size: size, scale: scale)

        // ── Reasoning labels (second pass, over the bars) ──
        // Give each thought beat a short readable gist beside its diamond so
        // the strip shows WHAT the agent thought, not just an opaque dot. Drawn
        // after the bars (on top) and decluttered left→right so a dense burst
        // reads as a few chips rather than an illegible pile.
        var lastRightByRow: [Int: CGFloat] = [:]
        for layout in engine.layouts.sorted(by: { $0.x < $1.x }) {
            guard let node = nodeByID[layout.nodeID], node.category == .reasoning,
                  let label = reasoningLabel(node) else { continue }
            let cy = sy(CGFloat(layout.y))
            let labelX = sx(layout.x + ThoughtGraphLayoutEngine.markerSize / 2) + 8
            guard labelX < size.width - Self.sidePad else { continue }
            let row = Int((CGFloat(layout.y) / ThoughtGraphLayoutEngine.subRowPitch).rounded())
            if let lastRight = lastRightByRow[row], labelX < lastRight + 4 { continue }
            let estWidth = CGFloat(label.count) * 4.6   // ~7.5pt medium
            lastRightByRow[row] = labelX + estWidth
            context.draw(
                Text(label)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(node.category.color.opacity(0.95)),
                at: CGPoint(x: labelX, y: cy),
                anchor: .leading
            )
        }
    }

    /// Full-height compaction rules for the strip, positioned by the same
    /// time→x scale as the bars (`world x=0` sits at `leftGutter`, mapped from
    /// wall-clock via `engine.timeOrigin`). A `/compress` is solid; an
    /// automatic fold is dashed and quieter. Skipped when the turn has no real
    /// time origin (nothing to anchor to) — never faked.
    private func drawCompactionFolds(context: GraphicsContext, size: CGSize, scale: CGFloat) {
        guard !compactions.isEmpty, let t0 = engine.timeOrigin else { return }
        func sx(_ worldX: CGFloat) -> CGFloat { Self.sidePad + worldX * scale }
        let axisTop = size.height - Self.axisBandHeight

        for marker in compactions {
            let worldX = ThoughtGraphLayoutEngine.leftGutter
                + marker.at.timeIntervalSince(t0) * ThoughtGraphLayoutEngine.pixelsPerSecond
            let x = sx(worldX)
            guard x >= Self.sidePad, x <= size.width - Self.sidePad else { continue }

            var rule = Path()
            rule.move(to: CGPoint(x: x, y: Self.topPad))
            rule.addLine(to: CGPoint(x: x, y: axisTop))
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

    /// Short glanceable gist for a reasoning beat — the decision label
    /// (`context`) or the first line of its summary, capped so it stays a chip.
    private func reasoningLabel(_ node: ThoughtGraphNode) -> String? {
        let raw = node.context ?? node.summary?.components(separatedBy: "\n").first
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text.count > 32 ? String(text.prefix(32)) + "…" : text
    }
}
