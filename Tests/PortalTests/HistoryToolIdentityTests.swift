import Foundation
import Testing
@testable import Portal

/// Gateway history carries no tool_call_id, so `parseHistoryMessages` synthesizes
/// one — and that synthetic id becomes SwiftUI's `ForEach` identity in the tool
/// trail. It used to be derived from the message count, which is constant across
/// a run of consecutive tool entries, so every tool in a resumed turn shared an
/// id. SwiftUI logged "the ID hist_3 occurs multiple times" hundreds of times and
/// rebuilt rows instead of diffing them, pinning the main thread for as long as
/// the transcript was on screen. These tests pin the identity contract.
@Suite("Synthetic tool identity in resumed history")
internal struct HistoryToolIdentityTests {
    private func tool(_ name: String, context: String? = nil) -> [String: AnyCodable] {
        var raw: [String: AnyCodable] = ["role": AnyCodable("tool"), "name": AnyCodable(name)]
        if let context { raw["context"] = AnyCodable(context) }
        return raw
    }

    private func assistant(_ text: String) -> [String: AnyCodable] {
        ["role": AnyCodable("assistant"), "text": AnyCodable(text)]
    }

    private func user(_ text: String) -> [String: AnyCodable] {
        ["role": AnyCodable("user"), "text": AnyCodable(text)]
    }

    @Test("Consecutive tool entries in one turn each get a distinct id")
    internal func consecutiveToolsAreUniquelyIdentified() throws {
        let raw = [
            user("go"),
            assistant("Working"),
            tool("Read"),
            tool("Grep"),
            tool("Edit"),
            tool("Bash"),
            assistant("Done")
        ]

        let messages = ChatViewModel.parseHistoryMessages(raw)
        let trail = try #require(messages.first(where: { !$0.toolCalls.isEmpty })).toolCalls
        #expect(trail.count == 4)
        #expect(Set(trail.map(\.id)).count == 4)
    }

    @Test("Ids stay unique across turns, not just within one")
    internal func idsAreUniqueAcrossTurns() {
        let raw = [
            assistant("First"),
            tool("Read"),
            tool("Grep"),
            assistant("Second"),
            tool("Read"),
            tool("Grep"),
            assistant("Third")
        ]

        let allIDs = ChatViewModel.parseHistoryMessages(raw).flatMap { $0.toolCalls.map(\.id) }
        #expect(allIDs.count == 4)
        #expect(Set(allIDs).count == 4)
    }

    @Test("The trail keeps history order and the entries' own detail")
    internal func trailPreservesOrderAndContext() throws {
        let raw = [
            assistant("Working"),
            tool("Read", context: "ChatViewModel.swift"),
            tool("Edit", context: "ConversationPanel.swift"),
            assistant("Done")
        ]

        let trail = try #require(ChatViewModel.parseHistoryMessages(raw).first).toolCalls
        #expect(trail.map(\.name) == ["Read", "Edit"])
        #expect(trail.map(\.context) == ["ChatViewModel.swift", "ConversationPanel.swift"])
        #expect(trail.allSatisfy { $0.isComplete })
    }

    @Test("Tools trailing the transcript still land on the last assistant turn")
    internal func trailingToolsAreFlushed() throws {
        let raw = [assistant("Working"), tool("Read"), tool("Grep")]
        let last = try #require(ChatViewModel.parseHistoryMessages(raw).last)
        #expect(Set(last.toolCalls.map(\.id)).count == 2)
    }
}
