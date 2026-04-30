import SwiftUI
import Lottie

/// Dark Manga skin — near-black background, dark gray bubbles, Lottie animated character
/// avatar, inline thinking/tool calls. Layout mirrors the Hermes Web UI pattern.
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

// MARK: - Message Bubble

/// Matches Web UI layout: avatar left, bubble right.
/// Thinking block and tool calls live inside the bubble.
private struct DarkMangaMessageBubble: View {
    let message: ChatMessage
    let persona: Persona

    private var expression: CharacterExpression {
        message.isStreaming ? .thinking : .idle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant {
                // Left: Lottie character avatar
                VStack(spacing: 4) {
                    LottieCharacterView(
                        expression: expression,
                        size: CGSize(width: 52, height: 52)
                    )
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                    Text(persona.name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                .frame(width: 52)
            }

            // Right: bubble content
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    // Thinking block — inside bubble, above content (Web UI pattern)
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        DarkMangaThinkingBlock(
                            reasoning: reasoning,
                            isStreaming: message.isStreaming
                        )
                    }

                    // Main content
                    if !message.content.isEmpty {
                        MarkdownContentView(text: message.content)
                            .foregroundStyle(Theme.primary)
                    }

                    // Completed tool calls — inside bubble, below content
                    if !message.toolCalls.isEmpty && !message.isStreaming {
                        DarkMangaInlineToolCalls(tools: message.toolCalls)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 2)
            }

            if message.role == .user {
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Thinking Block (inside bubble)

/// Collapsible reasoning block with dashed separator, matching Web UI's .thinking-block
private struct DarkMangaThinkingBlock: View {
    let reasoning: String
    let isStreaming: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                    Text(isStreaming ? "Thinking…" : "Reasoning")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)

            // Body (expanded)
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
        .onAppear { if isStreaming { isExpanded = true } }
    }
}

// MARK: - Inline Tool Calls (inside bubble)

/// Compact tool call rows inside the bubble, matching Web UI's .tool-calls-inline
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

/// Matches Web UI's .streaming-indicator: larger character + live tool list.
/// Shown below all messages during active streaming.
private struct DarkMangaStreamingIndicator: View {
    let avatarState: AvatarState
    let activeToolCalls: [String: ToolCallRecord]
    let personaName: String

    private var expression: CharacterExpression {
        switch avatarState {
        case .idle:     .idle
        case .thinking: .thinking
        case .speaking: .happy
        case .toolUse:  .thinking
        case .error:    .confused
        }
    }

    private var orderedTools: [ToolCallRecord] {
        let running = activeToolCalls.values.filter { !$0.isComplete }.sorted { $0.id < $1.id }
        let completed = activeToolCalls.values.filter { $0.isComplete }.sorted { $0.id < $1.id }
        return running + completed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Left: Larger animated character
            LottieCharacterView(
                expression: expression,
                size: CGSize(width: 80, height: 80)
            )
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
            )

            // Right: State + live tool list
            VStack(alignment: .leading, spacing: 6) {
                // State label
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

                // Live tool rows
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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

// MARK: - Streaming Braille Spinner

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
