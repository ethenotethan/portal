import SwiftUI

// MARK: - Turn model

/// One turn's worth of thought-graph data, reconstructed from a persisted
/// assistant `ChatMessage`. A session is an ensemble of these — the per-turn
/// flamechart, replayable across the whole conversation.
internal struct SessionTurn: Identifiable {
    internal let id: UUID
    /// 1-based turn number for display.
    internal let index: Int
    /// The user prompt that opened this turn, trimmed for the rail label.
    internal let prompt: String
    /// Assistant reply preview, for the rail subtitle.
    internal let replyPreview: String
    /// Nodes composed for this turn: tool bars (always) + subagent lanes and
    /// reasoning beats (present when the turn carried a graph snapshot).
    internal let nodes: [ThoughtGraphNode]
    /// Context-compaction folds during this turn, drawn as full-height rules
    /// across the flamechart. Empty for turns with no compaction (the common
    /// case) or persisted before compaction capture existed.
    internal let compactions: [CompactionMarker]
    /// Skills active during this turn ("what"). Live-only for now — the current
    /// turn carries `ChatViewModel.activeSkills`; past turns are empty because
    /// skills aren't persisted per-turn yet (the skills panel shows an honest
    /// "not recorded" state rather than inventing them).
    internal let skills: [SkillInfo]
    /// Tool-call count, for the rail badge.
    internal let toolCount: Int
    /// Whether full depth (reasoning/subagents) is available, vs tool-only —
    /// true for turns recorded before graph-snapshot capture or resumed from
    /// gateway history without timing.
    internal let toolsOnly: Bool

    internal var title: String {
        prompt.isEmpty ? "Turn \(index)" : prompt
    }
}

internal enum SessionTurnBuilder {
    /// Split a transcript into per-turn graphs. Each assistant message is one
    /// turn; the nearest preceding user message supplies the prompt label.
    /// MainActor-isolated because `composeTimeline` is (it lives on the engine).
    @MainActor
    internal static func turns(from messages: [ChatMessage]) -> [SessionTurn] {
        var turns: [SessionTurn] = []
        var pendingPrompt = ""
        var turnIndex = 0

        for message in messages {
            switch message.role {
            case .user:
                pendingPrompt = message.content
            case .assistant:
                // Skip empty assistant turns (no tools, no reply) — nothing to graph.
                guard !message.toolCalls.isEmpty
                    || message.graphSnapshot?.isEmpty == false
                    || !message.content.isEmpty else { continue }
                turnIndex += 1
                let snapshot = message.graphSnapshot
                let nodes = ThoughtGraphLayoutEngine.composeTimeline(
                    tools: message.toolCalls.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) },
                    agentNodes: snapshot?.agentNodes ?? [],
                    reasoningNodes: snapshot?.reasoningNodes ?? []
                )
                turns.append(SessionTurn(
                    id: message.id,
                    index: turnIndex,
                    prompt: pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    replyPreview: String(message.content.prefix(80)),
                    nodes: nodes,
                    compactions: snapshot?.compactions ?? [],
                    skills: [],
                    toolCount: message.toolCalls.count,
                    toolsOnly: snapshot == nil || snapshot?.isEmpty == true
                ))
                pendingPrompt = ""
            }
        }
        return turns
    }
}

// MARK: - Per-turn metrics

/// The consolidated numbers for one turn, derived purely from its nodes — no
/// invention. Drives the metrics bar so a turn reads at a glance (how long, how
/// many tools/thoughts/subagents, what it cost) before you dive into the graph.
private struct TurnMetrics {
    let toolCount: Int
    let reasoningCount: Int
    let subagentCount: Int
    let errorCount: Int
    let compactionCount: Int
    /// Wall-clock span of the turn (first start → last finish). nil when no
    /// node carried a timestamp (a tools-only history snapshot).
    let duration: TimeInterval?
    /// Summed subagent token/cost rollups. nil when nothing reported usage.
    let totalTokens: Int?
    let totalCostUSD: Double?

    init(turn: SessionTurn) {
        let nodes = turn.nodes
        self.toolCount = turn.toolCount
        self.reasoningCount = nodes.filter { $0.category == .reasoning }.count
        self.subagentCount = nodes.filter { $0.isAgent }.count
        self.errorCount = nodes.filter { $0.isError }.count
        self.compactionCount = turn.compactions.count

        let starts = nodes.compactMap(\.startedAt)
        let ends = nodes.compactMap { $0.completedAt ?? $0.startedAt }
        if let first = starts.min(), let last = ends.max(), last > first {
            self.duration = last.timeIntervalSince(first)
        } else {
            self.duration = nil
        }

        let tokens = nodes.compactMap(\.totalTokens).reduce(0, +)
        self.totalTokens = tokens > 0 ? tokens : nil
        let cost = nodes.compactMap(\.costUSD).reduce(0, +)
        self.totalCostUSD = cost > 0 ? cost : nil
    }
}

// MARK: - Session thought graph

/// The per-session Agent Thought Graph, as a **turn view**: a session is an
/// ensemble of per-turn flamecharts, and you page through them.
///
/// - A left **rail** lists every turn (prompt, tool count, live badge).
/// - Selecting a turn shows a consolidated **metrics bar** (duration, tools,
///   thoughts, subagents, tokens/cost, compactions, errors) — the turn at a
///   glance — over the turn's **flamechart**, which is the main surface.
/// - The flamechart fits its box and grows in place while streaming; it can be
///   expanded to true fullscreen.
///
/// This replaces the earlier free-form multi-panel dashboard (drag/resize/add
/// panel), which buried the per-turn story under chrome. The flamechart still
/// owns the only 30 Hz redraw timer, so there's exactly one live graph at a time.
internal struct SessionThoughtGraphView: View {
    internal let turns: [SessionTurn]
    /// The local reasoning model is summarizing right now (heartbeat).
    internal var isThinking: Bool = false
    /// The session is streaming — the last turn is the live "Current turn", so
    /// its flamechart grows in real time.
    internal var isStreaming: Bool = false
    /// Newest turn is selected by default (most recent activity).
    @State private var selectedTurnID: UUID?
    /// Selection shared between the flamechart (when) and its detail panel.
    @State private var selectedNodeID: String?
    /// True while the flamechart is presented true-fullscreen (whole view).
    @State private var isFlamechartFullscreen = false
    /// The one flamechart engine, owned here — never one-per-panel (the
    /// anti-beachball rule: exactly one 30 Hz redraw timer).
    @StateObject private var engine = ThoughtGraphLayoutEngine()

    internal var onJumpToTool: ((String) -> Void)?

    private var selectedTurn: SessionTurn? {
        turns.first { $0.id == selectedTurnID } ?? turns.last
    }

    /// Whether the selected turn is the live one (last turn while streaming) —
    /// gates the flamechart's growing right edge and the thinking heartbeat.
    private var selectedTurnIsLive: Bool {
        isStreaming && selectedTurn?.id == turns.last?.id
    }

    internal var body: some View {
        if turns.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                turnRail
                    .frame(width: 200)
                Divider().overlay(Theme.border)
                turnDetail
            }
            .onAppear { if selectedTurnID == nil { selectedTurnID = turns.last?.id } }
            // Clear cross-highlight when switching turns (ids don't carry over).
            .onChange(of: selectedTurnID) { _, _ in selectedNodeID = nil }
            // True-fullscreen flamechart: covers the whole view, close returns.
            .overlay {
                if isFlamechartFullscreen, let turn = selectedTurn {
                    fullscreenFlamechart(turn: turn)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Turn detail (metrics bar + flamechart)

    private var turnDetail: some View {
        VStack(spacing: 0) {
            if let turn = selectedTurn {
                metricsBar(for: turn)
                Divider().overlay(Theme.border)
                flamechart(for: turn, onExpand: {
                    withAnimation(.easeInOut(duration: 0.2)) { isFlamechartFullscreen = true }
                })
                // Re-seed the flamechart engine when the turn changes.
                .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The turn's flamechart — the main surface. Fits its box and grows in
    /// place; `onExpand` (when provided) shows the expand affordance.
    private func flamechart(for turn: SessionTurn, onExpand: (() -> Void)?) -> some View {
        ThoughtGraphView(
            engine: engine,
            nodes: turn.nodes,
            compactions: turn.compactions,
            isStreaming: selectedTurnIsLive,
            isThinking: isThinking && selectedTurnIsLive,
            usageSummary: nil,
            selection: $selectedNodeID,
            onJumpToTool: onJumpToTool,
            onExpand: onExpand
        )
    }

    // MARK: - Metrics bar

    /// The consolidated per-turn header: turn number + prompt, then a row of
    /// metric chips. Everything is derived from the turn's nodes — a chip is
    /// hidden when its value is zero/unknown rather than showing a fake "0".
    private func metricsBar(for turn: SessionTurn) -> some View {
        let m = TurnMetrics(turn: turn)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Turn \(turn.index)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                if selectedTurnIsLive {
                    liveBadge
                }
                Text(turn.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 6) {
                if let dur = m.duration {
                    metricChip("timer", DurationFormatter.short(dur), Theme.secondary)
                }
                metricChip("wrench.and.screwdriver", "\(m.toolCount) tools", Theme.secondary)
                if m.reasoningCount > 0 {
                    metricChip("diamond.fill", "\(m.reasoningCount) thoughts", Theme.graphReasoning)
                }
                if m.subagentCount > 0 {
                    metricChip("brain", "\(m.subagentCount) subagents", Theme.agentAccent)
                }
                if let tokens = m.totalTokens {
                    metricChip("number.circle", "\(tokens) tok", Theme.secondary)
                }
                if let cost = m.totalCostUSD {
                    metricChip("dollarsign.circle", String(format: "$%.4f", cost), Theme.secondary)
                }
                if m.compactionCount > 0 {
                    metricChip("arrow.triangle.2.circlepath.circle", "\(m.compactionCount) compacted", Theme.graphCompaction)
                }
                if m.errorCount > 0 {
                    metricChip("xmark.circle.fill", "\(m.errorCount) errors", .red)
                }
                if turn.toolsOnly {
                    metricChip("square.dashed", "tools only", Theme.tertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface.opacity(0.5))
    }

    private func metricChip(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.warning)
                .frame(width: 5, height: 5)
            Text("live")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.warning.opacity(0.12), in: Capsule())
    }

    // MARK: - Fullscreen flamechart

    /// True-fullscreen flamechart: fills the whole session-graph view, opaque
    /// background, with a close button. No expand affordance here (already
    /// expanded). Its own engine instance so it doesn't fight the inline one's
    /// camera/layout state.
    @StateObject private var fullscreenEngine = ThoughtGraphLayoutEngine()

    private func fullscreenFlamechart(turn: SessionTurn) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.background.ignoresSafeArea()
            ThoughtGraphView(
                engine: fullscreenEngine,
                nodes: turn.nodes,
                compactions: turn.compactions,
                isStreaming: selectedTurnIsLive,
                isThinking: isThinking && selectedTurnIsLive,
                usageSummary: nil,
                selection: $selectedNodeID,
                onJumpToTool: onJumpToTool
            )
            .id(turn.id)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isFlamechartFullscreen = false }
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Exit fullscreen")
            .padding(.top, 64)
            .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Turn rail

    private var turnRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(turns) { turn in
                    turnRow(turn)
                }
            }
            .padding(10)
        }
        .background(Theme.surface.opacity(0.4))
    }

    private func turnRow(_ turn: SessionTurn) -> some View {
        let isSelected = turn.id == (selectedTurn?.id)
        let isLive = isStreaming && turn.id == turns.last?.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Turn \(turn.index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.primary)
                if isLive {
                    Circle()
                        .fill(Theme.warning)
                        .frame(width: 5, height: 5)
                        .help("Current turn — streaming now")
                }
                Spacer()
                Text("\(turn.toolCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                if turn.toolsOnly {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.tertiary)
                        .help("Tool calls only — full depth wasn't recorded for this turn")
                }
            }
            Text(turn.title)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedTurnID = turn.id }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)
            Text("No activity in this session")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("Tool calls and subagent activity appear here once the agent works a turn.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
