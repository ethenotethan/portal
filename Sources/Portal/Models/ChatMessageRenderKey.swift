import Foundation

/// Everything a message bubble's appearance depends on, as an equatable value.
///
/// `ChatMessage` is not `Equatable` (it carries attachment download state and
/// graph snapshots that never affect the bubble), and the skin providers return
/// `AnyView`, which SwiftUI cannot compare — so on every streamed delta every
/// bubble in the transcript re-ran its body. `MessageBubbleHost` compares this
/// key instead, so only the bubble whose message actually changed re-renders.
///
/// Content is compared by value: a streaming message changes it on every delta
/// (and must re-render); a settled message never does.
internal struct ChatMessageRenderKey: Equatable, Hashable {
    internal let id: UUID
    internal let content: String
    internal let isStreaming: Bool
    internal let showAvatar: Bool
    internal let showTimestamp: Bool
    internal let status: String?
    internal let reasoning: String?
    internal let traceUpdatedAt: Date?
    internal let traceBlockCount: Int
    internal let toolCallSignature: [String]
    /// Each attachment's id and download phase. The chip renders a spinner, a
    /// thumbnail or a failure from `downloadState`, and a pre-fetch finishing is
    /// the only thing that changes on the message — a count alone froze the chip
    /// in its pre-download state once rows became equatable. The bytes are not
    /// compared.
    internal let attachmentStates: [String]
    internal let attachmentCount: Int
    internal let userAttachmentCount: Int
    internal let skillCount: Int
    internal let hasGraphSnapshot: Bool
    internal let usageTotal: Int?

    internal init(_ message: ChatMessage) {
        id = message.id
        content = message.content
        isStreaming = message.isStreaming
        showAvatar = message.showAvatar
        showTimestamp = message.showTimestamp
        status = message.status
        reasoning = message.reasoning
        traceUpdatedAt = message.thinkingTrace?.updatedAt
        traceBlockCount = message.thinkingTrace?.blocks.count ?? 0
        // A tool call's visible state is its completion and its summary; the
        // id keeps two calls of the same tool apart.
        toolCallSignature = message.toolCalls.map { "\($0.id)|\($0.isComplete)|\($0.summary ?? "")" }
        attachmentStates = message.attachments.map { attachment in
            switch attachment.downloadState {
            case .notStarted: "\(attachment.id)|idle"
            case .downloading(let progress): "\(attachment.id)|dl\(Int(progress * 20))"
            case .ready: "\(attachment.id)|ready"
            case .failed: "\(attachment.id)|failed"
            }
        }
        attachmentCount = message.attachments.count
        userAttachmentCount = message.userAttachments.count
        skillCount = message.skills.count
        hasGraphSnapshot = message.graphSnapshot.map { !$0.isEmpty } ?? false
        usageTotal = message.usage?.totalTokens
    }
}
