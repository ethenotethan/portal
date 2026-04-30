import SwiftUI

/// Dark Manga skin — near-black background, dark gray bubbles, line-art character,
/// pill-shaped tool cards. Matches the design spec with the confused mascot
/// reacting to the tool cascade.
struct DarkMangaSkin: ChatSkinProviding {
    let skin: ChatSkin = .darkManga

    func messageBubble(message: ChatMessage, persona: Persona) -> AnyView {
        DarkMangaMessageBubble(message: message, persona: persona)
            .eraseToAnyView()
    }

    func streamingPanel(
        state: AvatarState,
        activeToolCalls: [String: ToolCallRecord],
        personaName: String,
        accentColor: Color
    ) -> AnyView {
        AgentPanel(
            avatarState: state,
            activeToolCalls: activeToolCalls,
            personaName: personaName
        )
        .eraseToAnyView()
    }
}

// MARK: - Dark Manga Message Bubble

/// Dark gray bubble with avatar, white text, and timestamp.
/// Matches the design spec: #2a2a2a surface, 16px corners, generous padding.
private struct DarkMangaMessageBubble: View {
    let message: ChatMessage
    let persona: Persona

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar (assistant only)
            if message.role == .assistant {
                persona.bubbleAvatar(size: Theme.avatarSize)
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                // Bubble
                VStack(alignment: .leading, spacing: 8) {
                    if !message.content.isEmpty {
                        MarkdownContentView(text: message.content)
                            .foregroundStyle(Theme.primary)
                    }

                    // Reasoning (collapsible)
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        DarkMangaReasoning(reasoning: reasoning, isStreaming: message.isStreaming)
                    }

                    // Tool calls (completed, collapsed)
                    if !message.toolCalls.isEmpty && !message.isStreaming {
                        DarkMangaCompletedTools(tools: message.toolCalls)
                    }
                }
                .padding(.horizontal, Theme.bubblePaddingH)
                .padding(.vertical, Theme.bubblePaddingV)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.system(.caption2))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 4)
            }

            if message.role == .user {
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Reasoning

private struct DarkMangaReasoning: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(isStreaming ? "Thinking…" : "Reasoning")
                        .font(.system(.caption, weight: .medium))
                    if isStreaming { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear { if isStreaming { isExpanded = true } }
    }
}

// MARK: - Completed Tools

private struct DarkMangaCompletedTools: View {
    let tools: [ToolCallRecord]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Tool calls")
                        .font(.system(.caption, weight: .medium))
                    Text("(\(tools.count))")
                        .font(.system(.caption))
                }
                .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(tools) { tool in
                        ToolPillView(tool: tool, isRunning: false)
                    }
                }
            }
        }
    }
}
