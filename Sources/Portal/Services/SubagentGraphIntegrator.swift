import Foundation

// MARK: - Subagent Graph Integrator

/// Accumulates gateway `subagent.*` events into `ThoughtGraphNode` subtrees so
/// delegated agent loops render inside the live thought graph, nested under
/// the tool call that dispatched them.
///
/// Each spawned subagent becomes one **agent node** (id `agent-<subagent_id>`)
/// whose parent is the delegating tool call in the main chain (or the parent
/// agent node for recursive spawns). The subagent's own tool calls chain
/// sequentially beneath it — the visible shape of its react loop.
///
/// Turn-scoped like the rest of the thought graph: `reset()` on message.start.
@MainActor
final class SubagentGraphIntegrator: ObservableObject {

    /// Flattened agent subtrees, ordered agent-before-its-tools so downstream
    /// depth resolution can run in a single forward pass.
    @Published private(set) var agentNodes: [ThoughtGraphNode] = []

    // MARK: - Private State

    private struct AgentRun {
        var node: ThoughtGraphNode
        var toolNodes: [ThoughtGraphNode] = []
        var toolCounter = 0
        var thinkingTail = ""
    }

    /// subagentID → accumulated run, plus insertion order for stable output.
    private var runs: [String: AgentRun] = [:]
    private var order: [String] = []

    /// Debounce for token-rate publishes (thinking/progress). Structural
    /// events (spawn/tool/complete) still publish immediately.
    private var pendingPublishTask: Task<Void, Never>?

    /// Cap on the retained thinking tail per agent (detail-panel preview).
    private static let thinkingTailLimit = 4000

    // MARK: - Node IDs

    static func agentNodeID(for subagentID: String) -> String {
        "agent-\(subagentID)"
    }

    // MARK: - Event Ingestion

    /// Handle subagent.spawn_requested / subagent.start.
    /// - Parameter delegatingToolID: the main-chain tool call that was running
    ///   when the spawn arrived (the delegate/dispatch tool), if identifiable.
    func upsertAgent(payload: SubagentPayload, running: Bool, delegatingToolID: String?) {
        guard let sid = payload.subagentID, !sid.isEmpty else { return }

        if var run = runs[sid] {
            if running { run.node.startedAt = run.node.startedAt ?? Date() }
            if run.node.context?.isEmpty != false, !payload.goal.isEmpty {
                run.node.context = payload.goal
            }
            runs[sid] = run
            publish()
            return
        }

        // Recursive spawn: parent_id referencing a known subagent wins over
        // the delegating tool heuristic.
        var parentIDs: [String] = []
        if let pid = payload.parentID, runs[pid] != nil {
            parentIDs = [Self.agentNodeID(for: pid)]
        } else if let delegatingToolID {
            parentIDs = [delegatingToolID]
        }

        let node = ThoughtGraphNode(
            id: Self.agentNodeID(for: sid),
            name: "agent",
            context: payload.goal,
            isComplete: false,
            parentIDs: parentIDs,
            startedAt: running ? Date() : nil,
            agentID: sid,
            modelName: payload.model
        )
        runs[sid] = AgentRun(node: node)
        order.append(sid)
        publish()
    }

    /// Handle subagent.complete — final status, cost, and token rollup.
    func completeAgent(payload: SubagentCompletePayload) {
        guard let sid = payload.subagentID, var run = runs[sid] else { return }
        run.node.isComplete = true
        run.node.completedAt = Date()
        if let start = run.node.startedAt {
            run.node.durationSeconds = Date().timeIntervalSince(start)
        }
        run.node.costUSD = payload.costUSD
        if let i = payload.inputTokens, let o = payload.outputTokens {
            run.node.totalTokens = i + o
        }
        runs[sid] = run
        publish()
    }

    /// Handle subagent.tool — one step of the subagent's loop. Steps chain
    /// sequentially beneath the agent node.
    func recordTool(payload: SubagentToolPayload) {
        guard let sid = payload.subagentID, var run = runs[sid] else { return }
        run.toolCounter += 1
        let parentID = run.toolNodes.last?.id ?? run.node.id
        let node = ThoughtGraphNode(
            id: "\(run.node.id)-t\(run.toolCounter)",
            name: payload.toolName ?? "tool",
            context: payload.toolPreview ?? payload.text,
            isComplete: true,
            parentIDs: [parentID],
            startedAt: Date(),
            completedAt: Date(),
            ownerAgentID: sid
        )
        run.toolNodes.append(node)
        runs[sid] = run
        publish()
    }

    /// Handle subagent.thinking / subagent.progress. A nil subagentID falls
    /// back to the most recently spawned still-running agent.
    func appendThinking(_ text: String, subagentID: String?) {
        guard !text.isEmpty else { return }
        let sid = subagentID
            ?? order.last(where: { runs[$0]?.node.isComplete == false })
        guard let sid, var run = runs[sid] else { return }
        run.thinkingTail += text
        if run.thinkingTail.count > Self.thinkingTailLimit {
            run.thinkingTail = String(run.thinkingTail.suffix(Self.thinkingTailLimit))
        }
        run.node.agentThinking = run.thinkingTail
        runs[sid] = run
        schedulePublish()
    }

    /// Clear all accumulated runs (new conversation turn).
    func reset() {
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        runs = [:]
        order = []
        agentNodes = []
    }

    // MARK: - Publish

    /// Immediate publish for structural changes (node added/completed).
    private func publish() {
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        agentNodes = order.flatMap { sid -> [ThoughtGraphNode] in
            guard let run = runs[sid] else { return [] }
            return [run.node] + run.toolNodes
        }
    }

    /// Debounced publish for token-rate content updates (thinking text).
    /// Publishing `agentNodes` re-renders the graph sheet when it's open —
    /// per-token republish pins the main thread in SwiftUI layout.
    private func schedulePublish() {
        guard pendingPublishTask == nil else { return }
        pendingPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingPublishTask = nil
            self.publish()
        }
    }
}
