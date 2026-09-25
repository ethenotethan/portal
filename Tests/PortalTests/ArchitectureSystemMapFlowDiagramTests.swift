import Testing
import Foundation
@testable import Portal

@Suite("Architecture system map — flow diagrams as Mermaid")
internal struct ArchitectureSystemMapFlowDiagramTests {
    private func document() throws -> ArchitectureSystemMapDocument {
        let json = """
        {
          "nodes": [
            {"id": "hub:ChatViewModel", "kind": "hub", "label": "ChatViewModel", "history_key": "hub:ChatViewModel"},
            {"id": "owner:gw", "kind": "owner", "label": "GatewayClient", "history_key": "owner:hermes-services:GatewayClient"},
            {"id": "store:s", "kind": "store", "label": "Activity <Store>; \\"quoted\\"", "history_key": "store:domain-models:ActivityStore"}
          ],
          "edges": [],
          "pages": [{"id": "chat", "label": "Main chat view"}, {"id": "launch", "label": "App launch"}],
          "flows": [
            {"id": "send", "title": "Send", "steps": [
              {"from": "page:chat", "to": "hub:ChatViewModel", "relation": "triggers", "note": "Send button"},
              {"from": "hub:ChatViewModel", "to": "owner:hermes-services:GatewayClient", "relation": "calls", "note": ""},
              {"from": "owner:hermes-services:GatewayClient", "to": "store:domain-models:ActivityStore", "relation": "persists-to", "note": "after: reply #1"},
              {"from": "page:launch", "to": "hub:ChatViewModel", "relation": "constructs-at-launch", "note": ""},
              {"from": "nowhere:at:all", "to": "hub:ChatViewModel", "relation": "haunts", "note": ""}
            ]},
            {"id": "empty", "title": "Empty", "steps": []}
          ],
          "invariants": []
        }
        """
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        return ArchitectureSystemMapDocument.decode(try #require(value.dictionaryValue))
    }

    @Test("labels drop what Mermaid treats as structure and collapse whitespace")
    internal func labels() {
        #expect(ArchitectureSystemMapFlowDiagram.label("a;b:c#d<e>f\"g`h") == "a b c d e f g h")
        #expect(ArchitectureSystemMapFlowDiagram.label("  many   spaces \n here ") == "many spaces here")
        #expect(ArchitectureSystemMapFlowDiagram.label("").isEmpty)
    }

    @Test("participants resolve by history key, then id, then page pseudo-node, then the raw tail")
    internal func participants() throws {
        let map = try document()
        #expect(ArchitectureSystemMapFlowDiagram.participantLabel(for: "owner:hermes-services:GatewayClient", document: map) == "GatewayClient")
        #expect(ArchitectureSystemMapFlowDiagram.participantLabel(for: "hub:ChatViewModel", document: map) == "ChatViewModel")
        #expect(ArchitectureSystemMapFlowDiagram.participantLabel(for: "page:chat", document: map) == "User on Main chat view")
        #expect(ArchitectureSystemMapFlowDiagram.participantLabel(for: "page:launch", document: map) == "App entry points")
        #expect(ArchitectureSystemMapFlowDiagram.participantLabel(for: "nowhere:at:all", document: map) == "all")
    }

    @Test("messages are the relation with hyphens as spaces, plus the note")
    internal func messages() {
        let step = ArchitectureFlowStep(from: "a", to: "b", relation: "persists-to", note: "after commit")
        #expect(ArchitectureSystemMapFlowDiagram.messageText(for: step) == "persists to · after commit")
        let bare = ArchitectureFlowStep(from: "a", to: "b", relation: "calls", note: "")
        #expect(ArchitectureSystemMapFlowDiagram.messageText(for: bare) == "calls")
    }

    @Test("the diagram is a numbered sequence diagram with one participant per endpoint, in first-appearance order")
    internal func diagram() throws {
        let map = try document()
        let flow = try #require(map.flows.first { $0.id == "send" })
        let source = ArchitectureSystemMapFlowDiagram.mermaid(for: flow, document: map)
        let lines = source.split(separator: "\n").map(String.init)
        #expect(lines[0] == "sequenceDiagram")
        #expect(lines[1] == "  autonumber")
        #expect(lines[2] == "  participant p0 as User on Main chat view")
        #expect(lines[3] == "  participant p1 as ChatViewModel")
        #expect(lines[4] == "  participant p2 as GatewayClient")
        // Structural characters in a construction's label are dropped, not escaped.
        #expect(lines[5] == "  participant p3 as Activity Store quoted")
        #expect(lines[6] == "  participant p4 as App entry points")
        #expect(lines[7] == "  participant p5 as all")
        #expect(lines[8] == "  p0->>p1: triggers · Send button")
        #expect(lines[9] == "  p1->>p2: calls")
        // Asynchronous relations are dashed; the note's colon and hash are sanitised.
        #expect(lines[10] == "  p2-->>p3: persists to · after reply 1")
        #expect(lines[11] == "  p4->>p1: constructs at launch")
        #expect(lines[12] == "  p5->>p1: haunts")
        #expect(lines.count == 13)
        #expect(ArchitectureSystemMapFlowDiagram.mermaid(for: flow, document: map) == source, "deterministic")
    }

    @Test("a flow without steps is still a valid, empty sequence diagram")
    internal func emptyFlow() throws {
        let map = try document()
        let flow = try #require(map.flows.first { $0.id == "empty" })
        #expect(ArchitectureSystemMapFlowDiagram.mermaid(for: flow, document: map) == "sequenceDiagram\n  autonumber")
    }

    @Test("every flow of the real model renders to a diagram whose participants all resolve to labels")
    internal func realModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("architecture/model/model.json"))
        let model = try JSONDecoder().decode(AnyCodable.self, from: data)
        let interplay = try #require(model.dictionaryValue?["interplay"]?.dictionaryValue)
        let map = ArchitectureSystemMapDocument.decode(interplay)
        #expect(!map.flows.isEmpty)
        for flow in map.flows {
            let source = ArchitectureSystemMapFlowDiagram.mermaid(for: flow, document: map)
            #expect(source.hasPrefix("sequenceDiagram\n  autonumber\n"))
            #expect(!source.contains(" as \n"), "flow \(flow.id)")
            #expect(source.split(separator: "\n").filter { $0.contains("->>") }.count == flow.steps.count, "flow \(flow.id)")
        }
    }
}
