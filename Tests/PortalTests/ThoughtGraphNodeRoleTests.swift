import Testing
import Foundation
@testable import Portal

/// Guards the node-role seam that used to let reasoning render as a phantom
/// tool row. A `ThoughtGraphNode`'s role is now explicit (`role`), and the
/// tool-list filter keys off `isReasoning` rather than a `name == "reasoning"`
/// match — so a reasoning beat is excluded from the tool trace no matter what
/// it's named. See ThoughtGraphNode.role / RunningToolsPanel.toolNodes.
@Suite("ThoughtGraphNode role")
internal struct ThoughtGraphNodeRoleTests {

    @Test("An explicit reasoning role classifies as reasoning regardless of name")
    internal func explicitReasoningRoleWins() {
        // A reasoning beat that is NOT named the magic string "reasoning" — the
        // exact case that used to fall through into the tool-row branch.
        let node = ThoughtGraphNode(
            id: "r1", name: "thinking", isComplete: true, role: .reasoning
        )
        #expect(node.isReasoning)
        #expect(node.category == .reasoning)
        #expect(!node.isAgent)
    }

    @Test("A tool node is never reasoning even if it isn't named a known tool")
    internal func toolRoleNeverReasoning() {
        let node = ThoughtGraphNode(id: "t1", name: "some_custom_tool", role: .tool)
        #expect(!node.isReasoning)
        #expect(node.category == .other)
    }

    @Test("Name-based fallback keeps isReasoning consistent with category")
    internal func nameFallbackConsistency() {
        // A node built with the bare magic name and no explicit role: the
        // fallback must classify it as reasoning so isReasoning agrees with
        // category (both treat name == "reasoning" as reasoning). If they
        // disagreed, such a node would leak back into the tool list.
        let node = ThoughtGraphNode(id: "r1", name: "reasoning", isComplete: true)
        #expect(node.isReasoning)
        #expect(node.category == .reasoning)
    }

    @Test("An agentID forces the agent role even if a different role is passed")
    internal func agentIDForcesAgentRole() {
        let node = ThoughtGraphNode(id: "a1", name: "agent", role: .tool, agentID: "sub-1")
        #expect(node.isAgent)
        #expect(node.role == .agent)
        #expect(node.category == .agent)
    }

    @Test("role survives a Codable round-trip; a legacy blob without role decodes as nil")
    internal func codableRoundTrip() throws {
        let node = ThoughtGraphNode(id: "r1", name: "thinking", role: .reasoning)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ThoughtGraphNode.self, from: data)
        #expect(decoded.role == .reasoning)
        #expect(decoded.isReasoning)

        // A blob predating the field (no "role" key) must still decode, with the
        // name-based fallback carrying classification.
        let legacy = #"{"id":"r2","name":"reasoning","isComplete":true,"isError":false,"depth":0,"parentIDs":[]}"#
        let legacyNode = try JSONDecoder().decode(ThoughtGraphNode.self, from: Data(legacy.utf8))
        #expect(legacyNode.role == nil)
        #expect(legacyNode.isReasoning)
    }
}
