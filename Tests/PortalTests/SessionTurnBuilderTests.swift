import Testing
import Foundation
@testable import Portal

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

    @Test("the fingerprint is stable for an unchanged transcript")
    internal func fingerprintStable() {
        let messages = [user("q"), assistant("a", tools: [tool("t1")])]
        #expect(SessionTurnBuilder.fingerprint(of: messages) == SessionTurnBuilder.fingerprint(of: messages))
    }

    @Test("the fingerprint moves when a tool completes, a message grows, or a turn is added")
    internal func fingerprintTracksTurnShape() {
        let running = ToolCallRecord(id: "t1", name: "bash", isComplete: false, startedAt: Date())
        var completed = running
        completed.isComplete = true
        completed.completedAt = Date()
        let base = [user("q"), assistant("partial", tools: [running])]
        let baseprint = SessionTurnBuilder.fingerprint(of: base)

        #expect(SessionTurnBuilder.fingerprint(of: [user("q"), assistant("partial", tools: [completed])]) != baseprint)
        #expect(SessionTurnBuilder.fingerprint(of: [user("q"), assistant("partial text", tools: [running])]) != baseprint)
        #expect(SessionTurnBuilder.fingerprint(of: base + [user("again"), assistant("b", tools: [tool("t2")])]) != baseprint)
        #expect(SessionTurnBuilder.fingerprint(of: [user("other"), assistant("partial", tools: [running])]) != baseprint)
    }

    @Test("memoized turns match a fresh build and are reused for the same transcript")
    internal func memoizedTurnsMatchFreshBuild() {
        let messages = [
            user("first"), assistant("a", tools: [tool("t1")]),
            user("second"), assistant("b", tools: [tool("t2"), tool("t3")]),
        ]
        let fresh = SessionTurnBuilder.turns(from: messages)
        let memoized = SessionTurnBuilder.memoizedTurns(from: messages)
        #expect(memoized.map(\.id) == fresh.map(\.id))
        #expect(memoized.map(\.toolCount) == fresh.map(\.toolCount))
        #expect(memoized.map(\.prompt) == fresh.map(\.prompt))

        let before = SessionTurnBuilder.memoizedTranscriptCount
        _ = SessionTurnBuilder.memoizedTurns(from: messages)
        #expect(SessionTurnBuilder.memoizedTranscriptCount == before)

        let grown = messages + [user("third"), assistant("c", tools: [tool("t4")])]
        #expect(SessionTurnBuilder.memoizedTurns(from: grown).count == 3)
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

    @Test("compaction folds on a snapshot flow through to the turn")
    internal func compactionsCarryThrough() {
        let when = Date()
        let snap = TurnGraphSnapshot(
            agentNodes: [],
            reasoningNodes: [],
            compactions: [
                CompactionMarker(id: "c1", at: when, trigger: .automatic, detail: "context compacted"),
            ]
        )
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant("a", tools: [tool("t1")], snapshot: snap),
        ])
        #expect(turns.first?.compactions.count == 1)
        #expect(turns.first?.compactions.first?.trigger == .automatic)
        // A snapshot that carries ONLY compactions still counts as full-depth.
        #expect(turns.first?.toolsOnly == false)
    }

    @Test("a turn with no snapshot has no compaction folds")
    internal func noCompactionsWithoutSnapshot() {
        let turns = SessionTurnBuilder.turns(from: [
            user("q"), assistant("a", tools: [tool("t1")]),
        ])
        #expect(turns.first?.compactions.isEmpty == true)
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
