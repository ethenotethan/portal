import SwiftUI

/// Dark-mode message bubble — avatar + dark gray card + white text + timestamp.
/// Matches the design spec: #2a2a2a bubble, 16px corners, generous padding.
/// On iOS: user messages are right-aligned with accent-tinted background (Claude-style).
struct MessageBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject var personaManager: PersonaManager

    var body: some View {
        #if os(iOS)
        if message.role == .user {
            iosUserBubble
        } else {
            iosAssistantBubble
        }
        #else
        macOSBubble
        #endif
    }

    // MARK: - iOS User Bubble (right-aligned, accent-tinted)

    #if os(iOS)
    private var iosUserBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .trailing, spacing: 8) {
                    // User-sent media attachments (thumbnails)
                    if !message.userAttachments.isEmpty {
                        UserAttachmentsGrid(attachments: message.userAttachments, alignment: .trailing)
                    }

                    let displayContent = message.contentWithoutAttachments
                    if !displayContent.isEmpty {
                        Text(displayContent)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }

                    let attachments = MediaParser.extractAttachments(from: message.content)
                    if !attachments.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(attachments) { attachment in
                                AttachmentChipView(attachment: attachment)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.bubblePaddingH)
                .padding(.vertical, Theme.bubblePaddingV)
                .background(
                    Color.accentColor.opacity(0.85),
                    in: RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                )

                if message.showTimestamp {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary.opacity(0.5))
                        .padding(.trailing, 4)
                }
            }
        }
    }

    private var iosAssistantBubble: some View {
        assistantFullWidthBubble
    }
    #endif

    // MARK: - macOS Bubble (original left-aligned layout)

    #if os(macOS)
    @ViewBuilder
    private var macOSBubble: some View {
        if message.role == .assistant {
            assistantFullWidthBubble
        } else {
            macOSUserBubble
        }
    }

    private var macOSUserBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // Message bubble
                VStack(alignment: .leading, spacing: 8) {
                    // User-sent media attachments (thumbnails)
                    if !message.userAttachments.isEmpty {
                        UserAttachmentsGrid(attachments: message.userAttachments, alignment: .leading)
                    }

                    // Text content (MEDIA: tags stripped)
                    let displayContent = message.contentWithoutAttachments
                    if !displayContent.isEmpty {
                        if message.isStreaming && message.content.hasSuffix("…") == false {
                            // Streaming — show content as it arrives
                            LongResponseView(text: displayContent, isStreaming: message.isStreaming)
                        } else if displayContent.isEmpty && message.isStreaming {
                            // Streaming but no content yet — show nothing (agent panel handles it)
                            EmptyView()
                        } else {
                            LongResponseView(text: displayContent, isStreaming: message.isStreaming)
                        }
                    }

                    // File attachments from MEDIA: tags
                    let attachments = MediaParser.extractAttachments(from: message.content)
                    if !attachments.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(attachments) { attachment in
                                AttachmentChipView(attachment: attachment)
                            }
                        }
                    }

                    // Reasoning (collapsible)
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        ReasoningSection(reasoning: reasoning, isStreaming: message.isStreaming)
                    }

                    // Completed tool calls (collapsed in bubble)
                    if !message.toolCalls.isEmpty && !message.isStreaming {
                        CompletedToolsSection(tools: message.toolCalls)
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

            Spacer(minLength: 0)
        }
    }
    #endif

    // MARK: - Assistant Bubble (full-width transcript lane)

    private var assistantFullWidthBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) {
                let displayContent = message.contentWithoutAttachments
                if !displayContent.isEmpty {
                    if message.isStreaming && message.content.hasSuffix("…") == false {
                        LongResponseView(text: displayContent, isStreaming: message.isStreaming)
                    } else if displayContent.isEmpty && message.isStreaming {
                        EmptyView()
                    } else {
                        LongResponseView(text: displayContent, isStreaming: message.isStreaming)
                    }
                }

                let attachments = MediaParser.extractAttachments(from: message.content)
                if !attachments.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(attachments) { attachment in
                            AttachmentChipView(attachment: attachment)
                        }
                    }
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningSection(reasoning: reasoning, isStreaming: message.isStreaming)
                }

                if !message.toolCalls.isEmpty && !message.isStreaming {
                    CompletedToolsSection(tools: message.toolCalls)
                }
            }
            .padding(.horizontal, Theme.bubblePaddingH)
            .padding(.vertical, Theme.bubblePaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))

            if message.showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.system(.caption2))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// MARK: - Reasoning Section

private struct ReasoningSection: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    Text(isStreaming ? "Thinking…" : "Reasoning")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            if isStreaming { isExpanded = true }
        }
    }
}

// MARK: - Completed Tools Section

private struct CompletedToolsSection: View {
    let tools: [ToolCallRecord]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                    Text("Tool calls")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Text("(\(tools.count))")
                        .font(.system(.caption))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(tools) { tool in
                    ToolPillView(tool: tool, isRunning: false)
                }
            }
        }
    }
}

// MARK: - ChatMessage timestamp

extension ChatMessage {
    var timestamp: Date { Date() }
}

// MARK: - User Attachments Grid

/// Renders inline thumbnail images for user-sent media attachments
/// within their message bubble.
struct UserAttachmentsGrid: View {
    let attachments: [MediaAttachment]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(attachments) { attachment in
                UserAttachmentThumbnail(attachment: attachment)
            }
        }
    }
}

private struct UserAttachmentThumbnail: View {
    let attachment: MediaAttachment

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailImageView(data: attachment.thumbnailData, fallbackIcon: attachment.category.icon)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

            Text(attachment.fileName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}

