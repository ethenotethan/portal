import Testing
import Foundation
@testable import Portal

/// `MessageBubbleHost` is `Equatable` over this key so a streamed delta re-renders
/// the one bubble it changed and no other. The key must change for everything
/// a bubble draws and for nothing else.
@Suite("ChatMessage render key")
internal struct ChatMessageRenderKeyTests {

    private func message(_ content: String = "hello", streaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, isStreaming: streaming)
    }

    @Test("an unchanged message has an equal key across per-render copies")
    internal func stableAcrossCopies() {
        let original = message()
        var copy = original
        copy.attachments = [] // same count
        #expect(ChatMessageRenderKey(original) == ChatMessageRenderKey(copy))
        #expect(ChatMessageRenderKey(original).hashValue == ChatMessageRenderKey(copy).hashValue)
    }

    @Test("everything a bubble draws changes the key")
    internal func drawnStateChangesKey() {
        let base = message("hello", streaming: true)
        let baseKey = ChatMessageRenderKey(base)
        var delta = base
        delta.content += " world"
        #expect(ChatMessageRenderKey(delta) != baseKey, "a streamed delta")
        var settled = base
        settled.isStreaming = false
        #expect(ChatMessageRenderKey(settled) != baseKey, "streaming ended")
        var stamped = base
        stamped.showTimestamp = true
        #expect(ChatMessageRenderKey(stamped) != baseKey, "timestamp shown")
        var failed = base
        failed.status = "error"
        #expect(ChatMessageRenderKey(failed) != baseKey, "status")
        var reasoned = base
        reasoned.reasoning = "because"
        #expect(ChatMessageRenderKey(reasoned) != baseKey, "reasoning")
        var traced = base
        traced.thinkingTrace = ThinkingTrace(blocks: [ThinkingBlock(kind: .thinking, text: "hm")])
        #expect(ChatMessageRenderKey(traced) != baseKey, "thinking trace")
        var tooled = base
        tooled.toolCalls = [ToolCallRecord(id: "t1", name: "terminal")]
        #expect(ChatMessageRenderKey(tooled) != baseKey, "a tool call")
        var completed = tooled
        completed.toolCalls[0].isComplete = true
        completed.toolCalls[0].summary = "ok"
        #expect(ChatMessageRenderKey(completed) != ChatMessageRenderKey(tooled), "a tool call completing")
        var attached = base
        attached.attachments = [FileAttachment(path: "/tmp/x.pdf")]
        #expect(ChatMessageRenderKey(attached) != baseKey, "an attachment")
        var skilled = base
        skilled.skills = [TurnSkillRecord(name: "graphify", origin: .attached)]
        #expect(ChatMessageRenderKey(skilled) != baseKey, "a skill")
    }

    @Test("two different messages never share a key")
    internal func identityIsPartOfTheKey() {
        #expect(ChatMessageRenderKey(message()) != ChatMessageRenderKey(message()))
    }
}
