import SwiftUI

/// Renders a single chat message (user or assistant).
struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                // Assistant avatar
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.accentColor, in: Circle())
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Tool calls (shown above the text for assistant messages)
                if !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.toolCalls) { toolCall in
                            ToolCallView(toolCall: toolCall)
                        }
                    }
                }

                // Reasoning (collapsible)
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningView(text: reasoning)
                }

                // Main text content
                if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            message.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            message.isStreaming
                            ? RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                            : nil
                        )
                }

                // Streaming indicator
                if message.isStreaming && message.content.isEmpty {
                    HStack(spacing: 4) {
                        Text("Thinking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }

                // Status + usage
                if !message.isStreaming, message.role == .assistant {
                    HStack(spacing: 8) {
                        if let status = message.status, status != "complete" {
                            StatusBadge(status: status)
                        }
                        if let usage = message.usage {
                            Text("\(usage.totalTokens) tokens")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if message.role == .user {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: status == "interrupted" ? "pause.circle" : "exclamationmark.circle")
                .font(.caption2)
            Text(status)
                .font(.caption2)
        }
        .foregroundStyle(status == "interrupted" ? .orange : .red)
    }
}

// MARK: - Reasoning View

struct ReasoningView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Reasoning", isExpanded: $isExpanded) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : 3)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
