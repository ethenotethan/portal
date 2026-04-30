import SwiftUI

/// Renders a single chat message — TUI-aligned visual language.
///
/// Layout matches the Ink TUI:
///   User:      ❯ message text
///   Assistant: ◆ [ToolTrail: thinking + tools] + markdown body
///   (No avatar bubble — just glyph prefix + content)
struct MessageBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject var personaManager: PersonaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tool trail (thinking + tools) — shown above the content,
            // matching TUI's ToolTrail component
            let hasReasoning = (message.reasoning ?? "").isEmpty == false
            let hasTools = !message.toolCalls.isEmpty

            if hasReasoning || hasTools {
                ToolTrailView(
                    tools: message.toolCalls,
                    reasoning: message.reasoning,
                    reasoningTokens: nil,
                    toolTokens: nil,
                    isStreaming: message.isStreaming
                )
                .padding(.bottom, 4)
            }

            // Main content row: glyph + text
            HStack(alignment: .top, spacing: 0) {
                // Role glyph (3-char wide, matching TUI)
                Text(message.role == .user ? "❯ " : "◆ ")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(message.role == .user ? .primary : Color.accentColor)
                    .frame(width: 20, alignment: .leading)

                // Content
                if message.role == .user {
                    Text(message.content)
                        .textSelection(.enabled)
                } else {
                    if !message.content.isEmpty {
                        MarkdownContentView(text: message.content, isStreaming: message.isStreaming)
                            .textSelection(.enabled)
                    }

                    // Streaming indicator — when no content yet and no reasoning
                    if message.isStreaming && message.content.isEmpty && !hasReasoning {
                        HStack(spacing: 4) {
                            Text("Thinking")
                                .foregroundStyle(.secondary)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            // Status + usage (bottom metadata)
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
                .padding(.leading, 20)
                .padding(.top, 2)
            }
        }
        // User messages get vertical spacing; assistant messages flow tightly
        .padding(.top, message.role == .user ? 8 : 2)
        .padding(.bottom, message.role == .user ? 4 : 2)
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
