import Testing
import Foundation
@testable import HermesNative

/// Deterministic reasoning↔tool concept linking via shared salient tokens —
/// no model. Links only on high-signal tokens; stopwords never link.
@Suite("Concept linker")
internal struct ConceptLinkerTests {

    private func beat(_ id: String, _ text: String) -> ThoughtGraphNode {
        ThoughtGraphNode(id: id, name: "reasoning", context: text, isComplete: true, startedAt: Date())
    }

    private func tool(_ id: String, name: String, _ context: String) -> ThoughtGraphNode {
        ThoughtGraphNode(id: id, name: name, context: context, isComplete: true, startedAt: Date())
    }

    @Test("a beat links to the tool that shares a file concept")
    internal func linksOnSharedFile() {
        let links = ConceptLinker.link(nodes: [
            beat("r1", "I should read the AuthService implementation"),
            tool("t1", name: "read_file", "Reading Sources/AuthService.swift"),
        ])
        #expect(links.count == 1)
        #expect(links.first?.reasoningID == "r1")
        #expect(links.first?.toolID == "t1")
        #expect(links.first?.concept == "authservice")
    }

    @Test("generic shared words (stopwords) do not link")
    internal func stopwordsDontLink() {
        let links = ConceptLinker.link(nodes: [
            beat("r1", "let me check the file and read the status"),
            tool("t1", name: "read_file", "reading a file to check status"),
        ])
        #expect(links.isEmpty)
    }

    @Test("no link when concepts don't overlap")
    internal func noOverlapNoLink() {
        let links = ConceptLinker.link(nodes: [
            beat("r1", "thinking about the Kubernetes deployment"),
            tool("t1", name: "read_file", "Reading Sources/Payment.swift"),
        ])
        #expect(links.isEmpty)
    }

    @Test("one beat links to multiple tools sharing the concept")
    internal func fanOut() {
        let links = ConceptLinker.link(nodes: [
            beat("r1", "refactoring the GatewayClient connection logic"),
            tool("t1", name: "read_file", "Reading GatewayClient.swift"),
            tool("t2", name: "patch", "Editing GatewayClient.swift"),
        ])
        #expect(links.count == 2)
        #expect(Set(links.map(\.toolID)) == ["t1", "t2"])
    }

    @Test("tool-to-tool pairs are not linked (only reasoning↔tool)")
    internal func onlyReasoningToTool() {
        let links = ConceptLinker.link(nodes: [
            tool("t1", name: "read_file", "Reading GatewayClient.swift"),
            tool("t2", name: "patch", "Editing GatewayClient.swift"),
        ])
        #expect(links.isEmpty)
    }
}
