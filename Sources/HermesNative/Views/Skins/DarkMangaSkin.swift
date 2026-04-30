import SwiftUI
import Lottie

/// Dark Manga skin — near-black background, dark gray bubbles, inline thinking/tool calls.
/// Avatar is rendered as a singleton floating overlay by ChatView, not by the skin.
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
        DarkMangaStreamingIndicator(
            avatarState: state,
            activeToolCalls: activeToolCalls,
            personaName: personaName
        )
        .eraseToAnyView()
    }
}

// MARK: - Layout

private enum Layout {
    static let bubbleRadius: CGFloat = 14
    static let bubblePaddingH: CGFloat = 14
    static let bubblePaddingV: CGFloat = 10
    static let maxBubbleWidth: CGFloat = 680
    static let turnSpacing: CGFloat = 16
}

// MARK: - Message Bubble

private struct DarkMangaMessageBubble: View {
    let message: ChatMessage
    let persona: Persona

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    // ── User: right-aligned, accent-tinted ──
    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Layout.bubblePaddingH)
                    .padding(.vertical, Layout.bubblePaddingV)
                    .background(
                        Theme.accent.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: Layout.bubbleRadius)
                    )
                    .frame(maxWidth: Layout.maxBubbleWidth, alignment: .trailing)

                if message.showTimestamp {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary.opacity(0.5))
                        .padding(.trailing, 4)
                }
            }
        }
        .padding(.bottom, Layout.turnSpacing)
    }

    /// Attachments parsed from MEDIA: tags in this message.
    private var attachments: [FileAttachment] {
        MediaParser.extractAttachments(from: message.content)
    }

    /// Content with MEDIA: lines stripped for display.
    private var displayContent: String {
        message.contentWithoutAttachments
    }

    // ── Assistant: left-aligned, no avatar (handled by ChatView overlay) ──
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoning, !reasoning.isEmpty, !message.isStreaming {
                    DarkMangaThinkingBlock(reasoning: reasoning)
                }

                if !displayContent.isEmpty {
                    MarkdownContentView(text: displayContent)
                        .foregroundStyle(Theme.primary)
                }

                if !attachments.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChipView(attachment: attachment)
                        }
                    }
                }

                if !message.toolCalls.isEmpty && !message.isStreaming {
                    DarkMangaInlineToolCalls(tools: message.toolCalls)
                }
            }
            .padding(.horizontal, Layout.bubblePaddingH)
            .padding(.vertical, Layout.bubblePaddingV)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Layout.bubbleRadius))

            if message.showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary.opacity(0.5))
                    .padding(.leading, 4)
            }
        }
        .frame(maxWidth: Layout.maxBubbleWidth, alignment: .leading)
        .padding(.bottom, Layout.turnSpacing)
    }
}

// MARK: - Thinking Block

private struct DarkMangaThinkingBlock: View {
    let reasoning: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(size: 12, design: .monospaced))
                    .italic()
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 10)
                    .overlay(
                        Rectangle()
                            .fill(Theme.accent.opacity(0.5))
                            .frame(width: 2),
                        alignment: .leading
                    )
                    .textSelection(.enabled)
            }
        }
        .padding(.bottom, 8)
        .overlay(
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Theme.border)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Inline Tool Calls

private struct DarkMangaInlineToolCalls: View {
    let tools: [ToolCallRecord]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                    Image(systemName: "wrench.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text("Tool calls")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text("(\(tools.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 4) {
                    ForEach(tools) { tool in
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                            Text(tool.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.primary)
                            Text(tool.context ?? tool.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Streaming Indicator
// No avatar — rendered by ChatView as singleton floating overlay.

private struct DarkMangaStreamingIndicator: View {
    let avatarState: AvatarState
    let activeToolCalls: [String: ToolCallRecord]
    let personaName: String

    private var orderedTools: [ToolCallRecord] {
        let running = activeToolCalls.values.filter { !$0.isComplete }.sorted { $0.id < $1.id }
        let completed = activeToolCalls.values.filter { $0.isComplete }.sorted { $0.id < $1.id }
        return running + completed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StreamingBrailleSpinner(state: avatarState)
                Text(stateLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text("·")
                    .foregroundStyle(Theme.tertiary)
                Text(personaName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            if !orderedTools.isEmpty {
                VStack(spacing: 4) {
                    ForEach(orderedTools) { tool in
                        HStack(spacing: 8) {
                            Image(systemName: "wrench.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                            Text(tool.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.primary)
                            Text(tool.context ?? tool.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                            Spacer()
                            if tool.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(.horizontal, Layout.bubblePaddingH)
        .padding(.vertical, Layout.bubblePaddingV)
        .frame(maxWidth: Layout.maxBubbleWidth, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Layout.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.bubbleRadius)
                .stroke(Theme.accent.opacity(0.15), lineWidth: 1)
        )
    }

    private var stateLabel: String {
        switch avatarState {
        case .idle:     "Idle"
        case .thinking: "Thinking"
        case .speaking: "Responding"
        case .toolUse:  "Running tools"
        case .error:    "Error"
        }
    }
}

// MARK: - Braille Spinner

private struct StreamingBrailleSpinner: View {
    let state: AvatarState
    @State private var frame = 0
    private let thinkFrames = ["⠋","⠙","⠹","⸦","⠴","⠦","⠇"]
    private let toolFrames = ["⡇","⣆","⣄","⣰","⢸","⢰","⢠"]
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var frames: [String] {
        state == .toolUse ? toolFrames : thinkFrames
    }

    var body: some View {
        Text(frames[frame % frames.count])
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .onReceive(timer) { _ in
                frame = (frame + 1) % frames.count
            }
    }
}
