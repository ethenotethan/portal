import Testing
import Foundation
@testable import HermesNative

/// Turn extraction for the per-session thought graph: each assistant message
/// is one turn, labeled by the preceding user prompt, carrying its persisted
/// tool calls (+ graph snapshot depth when present).
@MainActor
@Suite("Session turn builder")
internal struct SessionTurnBuilderTests {

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text)
    }

    private func assistant(
        _ text: String, tools: [ToolCallRecord] = [],
        snapshot: TurnGraphSnapshot? = nil
    ) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, toolCalls: tools, graphSnapshot: snapshot)
    }

    private func tool(_ id: String) -> ToolCallRecord {
        ToolCallRecord(id: id, name: "read_file", isComplete: true,
                       startedAt: Date(), completedAt: Date())
    }

    @Test("each assistant message becomes one turn, indexed from 1")
    internal func oneTurnPerAssistant() {
        let messages = [
            user("first"), assistant("a", tools: [tool("t1")]),
            user("second"), assistant("b", tools: [tool("t2")]),
        ]
        let turns = SessionTurnBuilder.turns(from: messages)
        #expect(turns.count == 2)
        #expect(turns[0].index == 1)
        #expect(turns[1].index == 2)
    }

    @Test("a turn is labeled by the user prompt that opened it")
    internal func promptAttribution() {
        let turns = SessionTurnBuilder.turns(from: [
            user("find the bug"), assistant("done", tools: [tool("t1")]),
        ])
        #expect(turns.first?.prompt == "find the bug")
        #expect(turns.first?.title == "find the bug")
    }

    @Test("a turn with no snapshot is tools-only")
    internal func toolsOnlyWhenNoSnapshot() {
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant("a", tools: [tool("t1")]),
        ])
        #expect(turns.first?.toolsOnly == true)
    }

    @Test("a turn carrying a non-empty snapshot is full-depth")
    internal func fullDepthWithSnapshot() {
        let snap = TurnGraphSnapshot(
            agentNodes: [ThoughtGraphNode(id: "agent-s1", name: "agent", agentID: "s1")],
            reasoningNodes: []
        )
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant("a", tools: [tool("t1")], snapshot: snap),
        ])
        #expect(turns.first?.toolsOnly == false)
        // Nodes include both the tool and the agent node.
        #expect((turns.first?.nodes.count ?? 0) >= 2)
    }

    @Test("empty assistant turns (no tools, no content) are skipped")
    internal func skipsEmptyTurns() {
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant(""),                       // empty → skipped
            user("q2"), assistant("real", tools: [tool("t1")]),
        ])
        #expect(turns.count == 1)
        #expect(turns.first?.index == 1)
        #expect(turns.first?.prompt == "q2")
    }

    @Test("toolCount reflects the turn's persisted tool calls")
    internal func toolCount() {
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant("a", tools: [tool("t1"), tool("t2"), tool("t3")]),
        ])
        #expect(turns.first?.toolCount == 3)
    }

    @Test("an empty transcript yields no turns")
    internal func emptyTranscript() {
        #expect(SessionTurnBuilder.turns(from: []).isEmpty)
    }
}
