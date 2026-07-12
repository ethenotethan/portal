import Testing
import Foundation
@testable import HermesNative

@Suite("Subagent Graph Integrator")
@MainActor
struct SubagentGraphIntegratorTests {

    private func spawnPayload(
        id: String,
        parentID: String? = nil,
        goal: String = "test goal",
        model: String? = "claude-sonnet-5"
    ) -> SubagentPayload {
        SubagentPayload(
            goal: goal, taskCount: 1, taskIndex: 0,
            subagentID: id, parentID: parentID, depth: 0, model: model
        )
    }

    @Test("spawn creates an agent node parented to the delegating tool")
    func spawnCreatesAgentNode() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: "tool_9")

        #expect(integrator.agentNodes.count == 1)
        let node = integrator.agentNodes[0]
        #expect(node.id == "agent-s1")
        #expect(node.isAgent)
        #expect(node.parentIDs == ["tool_9"])
        #expect(node.context == "test goal")
        #expect(node.modelName == "claude-sonnet-5")
        #expect(node.status == .running)
    }

    @Test("subagent tools chain sequentially under the agent node")
    func toolsChainUnderAgent() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.recordTool(payload: SubagentToolPayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", toolName: "grep", toolPreview: "pattern", text: nil
        ))
        integrator.recordTool(payload: SubagentToolPayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", toolName: "read_file", toolPreview: "a.swift", text: nil
        ))

        #expect(integrator.agentNodes.count == 3)
        let t1 = integrator.agentNodes[1]
        let t2 = integrator.agentNodes[2]
        #expect(t1.parentIDs == ["agent-s1"])
        #expect(t2.parentIDs == [t1.id])
        #expect(t1.ownerAgentID == "s1")
        #expect(t2.name == "read_file")
    }

    @Test("recursive spawn parents onto the parent agent node")
    func recursiveSpawnParentsOntoAgent() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: "tool_1")
        integrator.upsertAgent(payload: spawnPayload(id: "s2", parentID: "s1"), running: true, delegatingToolID: "tool_1")

        let child = integrator.agentNodes.first { $0.id == "agent-s2" }
        #expect(child?.parentIDs == ["agent-s1"])
    }

    @Test("complete marks node done and records cost/tokens")
    func completeRollsUpUsage() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.completeAgent(payload: SubagentCompletePayload(
            goal: "", taskCount: 1, taskIndex: 0,
            subagentID: "s1", parentID: nil, depth: 0,
            inputTokens: 1200, outputTokens: 300, apiCalls: 4, costUSD: 0.05,
            filesRead: nil, filesWritten: nil
        ))

        let node = integrator.agentNodes[0]
        #expect(node.isComplete)
        #expect(node.costUSD == 0.05)
        #expect(node.tokenTotal == 1500)
    }

    @Test("thinking with nil subagentID falls back to the running agent")
    func thinkingFallsBackToRunningAgent() async throws {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.appendThinking("pondering...", subagentID: nil)

        // Thinking publishes are debounced (250ms) to avoid per-token graph
        // re-renders. Poll rather than a single fixed sleep — under parallel
        // test load a one-shot 400ms wait races the debounce timer.
        for _ in 0..<40 where integrator.agentNodes[0].agentThinking == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(integrator.agentNodes[0].agentThinking == "pondering...")
    }

    @Test("reset clears all runs")
    func resetClears() {
        let integrator = SubagentGraphIntegrator()
        integrator.upsertAgent(payload: spawnPayload(id: "s1"), running: true, delegatingToolID: nil)
        integrator.reset()
        #expect(integrator.agentNodes.isEmpty)
    }

    @Test("layout assigns lanes: main loop first, one lane per agent")
    func layoutAssignsLanes() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let nodes = [
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true, startedAt: t0),
            ThoughtGraphNode(id: "t2", name: "delegate_task", startedAt: t0.addingTimeInterval(1)),
            ThoughtGraphNode(id: "agent-s1", name: "agent", parentIDs: ["t2"],
                             startedAt: t0.addingTimeInterval(2), agentID: "s1"),
            ThoughtGraphNode(id: "agent-s1-t1", name: "grep", parentIDs: ["agent-s1"],
                             startedAt: t0.addingTimeInterval(3), ownerAgentID: "s1"),
            ThoughtGraphNode(id: "t3", name: "read_file", startedAt: t0.addingTimeInterval(4)),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        #expect(engine.lanes.count == 2)
        #expect(engine.lanes[0].id == "main")
        #expect(engine.lanes[1].id == "s1")
        #expect(engine.lanes[1].isAgent)

        // Main-lane nodes share an x; agent-lane nodes share a different x.
        let x = { (id: String) in engine.layout(for: id)!.x }
        #expect(x("t1") == x("t2"))
        #expect(x("t2") == x("t3"))
        #expect(x("agent-s1") == x("agent-s1-t1"))
        #expect(x("t1") != x("agent-s1"))
    }

    @Test("layout orders rows chronologically and chains lanes with real edges")
    func layoutOrdersChronologically() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let nodes = [
            ThoughtGraphNode(id: "t2", name: "delegate_task", startedAt: t0.addingTimeInterval(1)),
            // Deliberately out of array order — startedAt must win.
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true, startedAt: t0),
            ThoughtGraphNode(id: "agent-s1", name: "agent", parentIDs: ["t2"],
                             startedAt: t0.addingTimeInterval(2), agentID: "s1"),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        let y = { (id: String) in engine.layout(for: id)!.y }
        #expect(y("t1") < y("t2"))
        #expect(y("t2") < y("agent-s1"))

        // Main chain edge t1→t2, spawn edge t2→agent-s1.
        #expect(engine.edges.contains(.init(from: "t1", to: "t2", kind: .main)))
        #expect(engine.edges.contains(.init(from: "t2", to: "agent-s1", kind: .spawn)))
    }

    @Test("agent with unknown parent spawn-links to the latest main-lane node")
    func orphanAgentFallsBack() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let nodes = [
            ThoughtGraphNode(id: "t1", name: "search_files", isComplete: true, startedAt: t0),
            ThoughtGraphNode(id: "t2", name: "read_file", isComplete: true,
                             startedAt: t0.addingTimeInterval(1)),
            ThoughtGraphNode(id: "agent-s1", name: "agent", parentIDs: ["missing"],
                             startedAt: t0.addingTimeInterval(2), agentID: "s1"),
        ]

        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)

        #expect(engine.edges.contains(.init(from: "t2", to: "agent-s1", kind: .spawn)))
    }

    @Test("composeTimeline merges tools, agents, and reasoning nodes")
    func composeTimelineMerges() {
        let nodes = ThoughtGraphLayoutEngine.composeTimeline(
            tools: [ToolCallRecord(id: "t1", name: "read_file", isComplete: true)],
            agentNodes: [ThoughtGraphNode(id: "agent-s1", name: "agent", agentID: "s1")],
            reasoningNodes: [ThoughtGraphNode(id: "r1", name: "reasoning", isComplete: true)]
        )
        #expect(nodes.count == 3)
        #expect(nodes.contains { $0.id == "t1" })
        #expect(nodes.contains { $0.isAgent })
        #expect(nodes.contains { $0.category == .reasoning })
    }

    @Test("delegate tool names classify as agent category")
    func delegateClassification() {
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "delegate_task") == .agent)
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "spawn_subagent") == .agent)
        #expect(ThoughtGraphLayoutEngine.ToolCategory.classify(name: "read_file") == .read)
    }
}
