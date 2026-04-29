import Foundation

/// A single message in the chat conversation.
struct ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    var toolCalls: [ToolCallRecord]
    var reasoning: String?
    var usage: UsageInfo?
    var status: String? // "complete", "interrupted", "error"

    enum Role: String, Equatable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        isStreaming: Bool = false,
        toolCalls: [ToolCallRecord] = [],
        reasoning: String? = nil,
        usage: UsageInfo? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.usage = usage
        self.status = status
    }
}

/// Record of a tool invocation within a conversation turn.
struct ToolCallRecord: Identifiable {
    let id: String         // tool_call_id from server
    var name: String
    var context: String?   // Preview text from tool.start
    var summary: String?   // Summary from tool.complete
    var durationSeconds: Double?
    var inlineDiff: String?
    var isComplete: Bool

    init(
        id: String,
        name: String,
        context: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        inlineDiff: String? = nil,
        isComplete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.context = context
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.inlineDiff = inlineDiff
        self.isComplete = isComplete
    }
}
