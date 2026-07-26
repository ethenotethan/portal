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
                    toolCount: message.toolCalls.count,
                    toolsOnly: snapshot == nil || snapshot?.isEmpty == true
                ))
                pendingPrompt = ""
            }
        }
        return turns
    }
}

// MARK: - Session thought graph

/// The per-session Agent Thought Graph: a session is an ensemble of per-turn
/// flamecharts. A left rail lists every turn; selecting one renders that
/// turn's `ThoughtGraphView` on the right. Only ONE graph is live at a time
/// (one engine, one 30 Hz canvas) — stacking N interactive canvases would run
/// N timers and N pan/zoom states, so we page through turns instead.
internal struct SessionThoughtGraphView: View {
    internal let turns: [SessionTurn]
    /// Newest turn is selected by default (most recent activity).
    @State private var selectedTurnID: UUID?
    @StateObject private var engine = ThoughtGraphLayoutEngine()

    internal var onJumpToTool: ((String) -> Void)?

    private var selectedTurn: SessionTurn? {
        turns.first { $0.id == selectedTurnID } ?? turns.last
    }

    internal var body: some View {
        if turns.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                turnRail
                    .frame(width: 220)
                Divider().overlay(Theme.border)
                if let turn = selectedTurn {
                    ThoughtGraphView(
                        engine: engine,
                        nodes: turn.nodes,
                        isStreaming: false,
                        usageSummary: nil,
                        onJumpToTool: onJumpToTool
                    )
                    // Re-seed the engine when the selected turn changes.
                    .id(turn.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { if selectedTurnID == nil { selectedTurnID = turns.last?.id } }
        }
    }

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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Turn \(turn.index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.primary)
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
