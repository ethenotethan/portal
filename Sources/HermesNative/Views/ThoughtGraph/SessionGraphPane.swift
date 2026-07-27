import SwiftUI

/// The macro all-turns Session Graph, extracted so it can be hosted either as a
/// fullscreen sheet (iOS) or as an in-canvas panel (macOS Canvas). It observes
/// the two per-turn graph integrators DIRECTLY — a parent that only observes
/// `ChatViewModel` won't re-render when nested subagent/reasoning publishes land
/// — so the graph rebuilds live as agent subtrees grow.
///
/// Every turn in the session is shown: persisted past turns (replayed from the
/// transcript with whatever depth was captured) plus, while streaming, the live
/// turn synthesized from the active integrators (which the transcript doesn't
/// hold until the turn completes).
internal struct SessionGraphPane: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    @ObservedObject internal var subagentGraph: SubagentGraphIntegrator
    @ObservedObject internal var reasoningGraph: ReasoningGraphIntegrator
    /// Cross-highlight / navigation: jump the transcript (or a sibling panel) to
    /// a tapped tool. Optional — the canvas may not coordinate a jump.
    internal var onJumpToTool: ((String) -> Void)?

    /// Stable id for the synthesized live turn so re-renders don't reset it.
    private let liveTurnID = UUID()

    private var turns: [SessionTurn] {
        var all = SessionTurnBuilder.turns(from: chatViewModel.messages)
        if chatViewModel.isStreaming || !chatViewModel.activeToolCalls.isEmpty {
            let liveNodes = ThoughtGraphLayoutEngine.composeTimeline(
                tools: Array(chatViewModel.activeToolCalls.values).sorted { $0.id < $1.id },
                agentNodes: subagentGraph.agentNodes,
                reasoningNodes: reasoningGraph.reasoningNodes
            )
            if !liveNodes.isEmpty {
                all.append(SessionTurn(
                    id: liveTurnID,
                    index: all.count + 1,
                    prompt: "Current turn",
                    replyPreview: "",
                    nodes: liveNodes,
                    compactions: chatViewModel.currentTurnCompactions,
                    skills: chatViewModel.activeSkills,
                    toolCount: chatViewModel.activeToolCalls.count,
                    toolsOnly: false
                ))
            }
        }
        return all
    }

    internal var body: some View {
        SessionThoughtGraphView(
            turns: turns,
            isThinking: reasoningGraph.isThinking,
            onJumpToTool: onJumpToTool
        )
    }
}
